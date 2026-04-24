"""Phase 4 — Convert a trained fit classifier checkpoint to Core ML.

Takes the `attr_best.pth` produced by `train_attributes.py` and emits:

    <out_dir>/AttributeClassifier_fp32.mlpackage    — intermediate, pre-compression
    <out_dir>/AttributeClassifier.mlpackage         — 6-bit palettized ship artifact
    WardrobeReDo/ML/AttributeClassifier.mlpackage    — if --copy-to-app

Option C single-head scope — emits only `fit_probs` (shape `(1, 5)`).
**Does not emit `texture_probs`**; the iOS decode path
(`AttributeClassifierService.decode`) handles the missing output via a
nil-tolerant MLMultiArray lookup, leaving `predictedTexture` at nil
with confidence 0.0 (see BLOCKERS.md#D-3).

Pod runbook (after `train_attributes.py` finishes):

    python export_attribute_classifier.py \\
        --checkpoint /workspace/training/attr-runs/.../attr_best.pth \\
        --out /workspace/training/attr-export \\
        --copy-to-app

Flags:
    --no-palettize   Skip the 6-bit k-means pass (emits FP32, ~10 MB).
                     Only use for debugging conversion; ship artifact
                     MUST be palettized.
    --copy-to-app    After palettization, copytree to
                     WardrobeReDo/ML/AttributeClassifier.mlpackage so the
                     Xcode project picks it up on the next build.

Design choices:
  - Normalization baked into the traced model (`ImageNetNormalize`
    module) rather than in the ImageType scale/bias args. Apple's
    `ImageType.scale` is a scalar — per-channel ImageNet normalization
    needs three different multipliers. Baking it in keeps the
    conversion boilerplate trivial.
  - Softmax baked into the traced model. Output name is `fit_probs`
    (matches `AttributeClassifierService.fitOutputKeys[0]`). The iOS
    decoder would auto-softmax logits anyway but we pick probs for
    clarity + so the output tensor values are already in [0, 1] (makes
    on-device debugging easier when inspecting `.mlpackage` outputs
    with Xcode's ML inspector).
  - ML Program format (not NeuralNetwork). Minimum deployment target
    iOS 17 to match `RFDETRSegFashion.mlpackage` and the app's build
    settings.
  - 6-bit per_tensor k-means palettization — reuses the same recipe
    as `export_coreml.py` so on-device latency characteristics are
    predictable.

See
`docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md`
§ 6 for the full iOS decode contract.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import coremltools as ct
    import torch
    import torch.nn as nn
    from coremltools.models import MLModel
    from coremltools.models.utils import rename_feature
    from coremltools.optimize.coreml import (
        OpPalettizerConfig,
        OptimizationConfig,
        palettize_weights,
    )
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)

from fashionpedia_attr_to_ios_enum import TRAINABLE_FIT_LABELS
from train_attributes import CROP_SIZE, IMAGENET_MEAN, IMAGENET_STD, build_model


NUM_CLASSES = len(TRAINABLE_FIT_LABELS)
DEFAULT_APP_DEST = Path("WardrobeReDo/ML/AttributeClassifier.mlpackage")


class ExportableFitClassifier(nn.Module):
    """Wraps the trained MobileNetV3-Small so the traced graph includes
    ImageNet normalization + softmax.

    The Core ML input is `ImageType(scale=1/255)` — pixel values reach
    this module in [0, 1] already. This module then applies per-channel
    `(x - mean) / std` and a softmax at the tail so the mlpackage
    emits clean probability vectors.
    """

    def __init__(self, inner: nn.Module) -> None:
        super().__init__()
        self.inner = inner
        # Register as buffers so they move with .to(device) and survive
        # state-dict round trips.
        self.register_buffer(
            "mean", torch.tensor(IMAGENET_MEAN, dtype=torch.float32).view(1, 3, 1, 1)
        )
        self.register_buffer(
            "std", torch.tensor(IMAGENET_STD, dtype=torch.float32).view(1, 3, 1, 1)
        )

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        # image: (1, 3, H, W), already scaled to [0, 1] by Core ML's
        # ImageType(scale=1/255).
        normalized = (image - self.mean) / self.std
        logits = self.inner(normalized)
        return torch.softmax(logits, dim=-1)


def load_checkpoint(checkpoint_path: Path) -> ExportableFitClassifier:
    """Instantiate `build_model()`, load the fine-tuned weights, wrap in
    the exportable module, and switch to eval mode."""
    inner = build_model()
    payload = torch.load(checkpoint_path, map_location="cpu")
    state = payload["model"] if isinstance(payload, dict) and "model" in payload else payload
    inner.load_state_dict(state)
    inner.eval()

    # Sanity-check the checkpoint's label contract matches the current
    # TRAINABLE_FIT_LABELS ordering. A mismatch here would silently
    # mis-label every iOS prediction.
    if isinstance(payload, dict) and "labels" in payload:
        ckpt_labels = list(payload["labels"])
        if ckpt_labels != TRAINABLE_FIT_LABELS:
            raise RuntimeError(
                "Label-order drift between checkpoint and "
                "fashionpedia_attr_to_ios_enum.TRAINABLE_FIT_LABELS.\n"
                f"  checkpoint:  {ckpt_labels}\n"
                f"  python-side: {TRAINABLE_FIT_LABELS}\n"
                "Retrain after syncing, or hand-edit the checkpoint."
            )

    wrapper = ExportableFitClassifier(inner)
    wrapper.eval()
    return wrapper


def trace(model: ExportableFitClassifier) -> torch.jit.ScriptModule:
    example = torch.rand(1, 3, CROP_SIZE, CROP_SIZE)
    with torch.no_grad():
        _ = model(example)  # warmup
        return torch.jit.trace(model, example, strict=False)


def convert_to_coreml(traced: torch.jit.ScriptModule) -> "ct.models.MLModel":
    """Convert to ML Program targeting iOS 17. FP32 precision avoids
    softmax overflow on rare-class logits; size is recovered via the
    6-bit palettization pass downstream.
    """
    image_input = ct.ImageType(
        name="image",
        shape=(1, 3, CROP_SIZE, CROP_SIZE),
        scale=1.0 / 255.0,
        bias=[0.0, 0.0, 0.0],
    )
    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT32,
    )
    return mlmodel


def rename_fit_output(mlmodel: "ct.models.MLModel") -> "ct.models.MLModel":
    """Force the softmax output to be named `fit_probs`.

    `coremltools.convert` auto-generates output names like `var_XXXX`
    when the traced module doesn't emit a named tensor. The iOS
    decoder probes for `fit_probs` (preferred), `fit_logits`, or
    `fit` via `AttributeClassifierService.fitOutputKeys`. Picking the
    preferred name up-front keeps the Swift-side auto-probe cheap.
    """
    spec = mlmodel.get_spec()
    outputs = list(spec.description.output)
    if not outputs:
        raise RuntimeError(
            "convert_to_coreml emitted zero outputs — graph tracing "
            "probably produced a dead model."
        )

    fit_output = None
    for out in outputs:
        shape = [int(s) for s in out.type.multiArrayType.shape]
        if shape and shape[-1] == NUM_CLASSES:
            fit_output = out
            break
    if fit_output is None:
        raise RuntimeError(
            f"No output with shape (…, {NUM_CLASSES}) found. Got: "
            f"{[(o.name, list(o.type.multiArrayType.shape)) for o in outputs]}"
        )

    if fit_output.name != "fit_probs":
        rename_feature(
            spec, fit_output.name, "fit_probs", rename_inputs=False, rename_outputs=True
        )

    return MLModel(spec, weights_dir=mlmodel.weights_dir)


def embed_metadata(mlmodel: "ct.models.MLModel") -> "ct.models.MLModel":
    """Stamp the label list + scope note into the mlpackage metadata.

    The labels list is the contract iOS decodes against. Embedding
    here means a future "which labels is this mlpackage for?" audit
    can read `mlpackage/Data/com.apple.CoreML/Metadata.json` without
    retraining.
    """
    mlmodel.user_defined_metadata["labels"] = ",".join(TRAINABLE_FIT_LABELS)
    mlmodel.user_defined_metadata["scope"] = "Option C (fit-only, single-head)"
    mlmodel.user_defined_metadata["num_classes"] = str(NUM_CLASSES)
    mlmodel.short_description = (
        "Wardrobe Re-Do — fit classifier (MobileNetV3-Small). "
        f"{NUM_CLASSES} classes: {', '.join(TRAINABLE_FIT_LABELS)}."
    )
    return mlmodel


def palettize(mlmodel: "ct.models.MLModel") -> "ct.models.MLModel":
    """6-bit k-means per_tensor — same recipe as RFDETR export for
    latency-predictable on-device inference."""
    cfg = OpPalettizerConfig(
        nbits=6,
        mode="kmeans",
        granularity="per_tensor",
    )
    return palettize_weights(mlmodel, OptimizationConfig(global_config=cfg))


def copy_to_app(mlpackage: Path, app_root: Path) -> Path:
    """Drop the ship artifact into the Xcode project. Overwrites any
    prior copy."""
    dest = app_root / DEFAULT_APP_DEST
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(mlpackage, dest)
    return dest


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument(
        "--out",
        type=Path,
        default=Path("./checkpoints/attr-export"),
        help="Output directory for .mlpackage files",
    )
    p.add_argument("--no-palettize", action="store_true")
    p.add_argument("--copy-to-app", action="store_true")
    p.add_argument(
        "--app-root",
        type=Path,
        default=None,
        help="Override the auto-detected repo root (grandparent of this "
        "script by default).",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    if not args.checkpoint.exists():
        print(f"FATAL: checkpoint {args.checkpoint} does not exist")
        return 1
    args.out.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("Fit classifier → Core ML export (Option C, single-head)")
    print("=" * 60)
    print(f"  checkpoint   {args.checkpoint}")
    print(f"  labels       {TRAINABLE_FIT_LABELS}")
    print(f"  out          {args.out}")
    print(f"  palettize    {'no' if args.no_palettize else 'yes (6-bit kmeans)'}")
    print(f"  copy to app  {'yes' if args.copy_to_app else 'no'}")
    print()

    print("[1/5] Loading checkpoint …")
    model = load_checkpoint(args.checkpoint)
    print("[2/5] Tracing …")
    traced = trace(model)
    print("[3/5] Converting to Core ML …")
    mlmodel = convert_to_coreml(traced)
    mlmodel = rename_fit_output(mlmodel)
    mlmodel = embed_metadata(mlmodel)

    fp32_path = args.out / "AttributeClassifier_fp32.mlpackage"
    if fp32_path.exists():
        shutil.rmtree(fp32_path)
    mlmodel.save(str(fp32_path))
    print(f"  wrote {fp32_path}")

    if args.no_palettize:
        print("\n[skip] Palettization disabled (--no-palettize).")
        ship_path = fp32_path
    else:
        print("[4/5] Palettizing (6-bit kmeans, per_tensor) …")
        compressed = palettize(mlmodel)
        ship_path = args.out / "AttributeClassifier.mlpackage"
        if ship_path.exists():
            shutil.rmtree(ship_path)
        compressed.save(str(ship_path))
        print(f"  wrote {ship_path}")

    # Final on-disk probe — make sure the `fit_probs` output name made
    # it through the save/load round-trip.
    reloaded = MLModel(str(ship_path))
    out_names = [o.name for o in reloaded.get_spec().description.output]
    if "fit_probs" not in out_names:
        print(
            f"WARNING: ship artifact exposes outputs {out_names}; expected "
            f"`fit_probs`. iOS decode will fall back to fitOutputKeys aliases."
        )
    else:
        print(f"  output names: {out_names}")

    if args.copy_to_app:
        app_root = args.app_root or Path(__file__).resolve().parents[3]
        print(f"\n[5/5] Copying to app bundle at {app_root / DEFAULT_APP_DEST} …")
        dest = copy_to_app(ship_path, app_root)
        print(f"  copied to {dest}")
    else:
        print("[5/5] Skipped app-bundle copy (--copy-to-app not set).")

    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
