"""Convert a trained RF-DETR-Seg-Small checkpoint to Core ML + 6-bit
palettize + copy to the iOS app bundle.

Produces:
    <out_dir>/RFDETRSegFashion_fp16.mlpackage   — intermediate FP16
    <out_dir>/RFDETRSegFashion.mlpackage        — 6-bit palettized (ship artifact)
    WardrobeReDo/Models/CoreML/RFDETRSegFashion.mlpackage   — copied if --copy-to-app

Runbook context: this is step 6-7 of the RUNPOD_RUNBOOK. Run on the GPU
pod after train.py finishes, then `scp` the resulting .mlpackage back
to the Mac for Xcode integration.

Usage:
    python export_coreml.py \\
        --checkpoint ./checkpoints/best.pth \\
        --out ./checkpoints/coreml \\
        --copy-to-app

Flags:
    --no-palettize   Skip the 6-bit pass (emits FP16 only, ~125 MB).
                     Only use for debugging conversion; ship artifact
                     MUST be palettized.
    --resolution N   Input spatial shape (default 1024, must match training).

Known failure modes (seen in previous DETR-family Core ML exports):
  - `aten::upsample_bicubic2d` not supported → pre-bake a fixed
    positional embedding before tracing (see comment inline).
  - Dynamic shape from an internal reshape → set `strict=False` on trace
    and verify the resulting .mlpackage has static output shapes.
  - FP16 overflow in softmax on certain backbones → force FP32 softmax
    via an `ct.convert` kwarg if the mlpackage predicts garbage.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

try:
    import coremltools as ct
    import torch
    from coremltools.models import MLModel
    from coremltools.models.utils import rename_feature
    from coremltools.optimize.coreml import (
        OpPalettizerConfig,
        OptimizationConfig,
        palettize_weights,
    )
    from rfdetr import RFDETRSegSmall
except ImportError as exc:
    print(
        f"Missing dependency: {exc}. Install with:\n"
        f"  pip install -r notebooks/training/requirements.txt"
    )
    sys.exit(1)

# RF-DETR-Seg's deformable attention natively produces a rank-6
# `sampling_offsets` tensor (B, L_q, n_heads, n_levels, n_points, 2) that
# Core ML (both coremltools 8.1 at conversion time, and Xcode's `coremlc`
# at compile time) rejects: reshape rank must be <= 5. An earlier version
# of this script tried to bypass the coremltools pre-flight check on the
# assumption that downstream passes + Neural Engine would still accept
# the rank-6 op. That produced an .mlpackage that `coremlc` rejected at
# Xcode build time with:
#     in operation sampling_offsets_1: Rank of the shape parameter must
#     be between 0 and 5 (inclusive) in reshape
# Real fix: monkey-patch rfdetr to fold (n_heads, n_levels) into one axis
# (HL = n_heads * n_levels) so the traced graph stays rank-5. Weights are
# untouched — no retraining needed.
from _rfdetr_coreml_patches import apply_rank5_patches
apply_rank5_patches()


NUM_CLASSES = 33  # keep in sync with train.py / prepare_fashionpedia.py


def _load_checkpoint(checkpoint: Path, resolution: int) -> RFDETRSegSmall:
    """Load the fine-tuned weights into an RFDETRSegSmall instance set
    up for inference.

    `pretrain_weights=None` is how rfdetr 1.4 skips the ~129 MB COCO
    weight download at construct time — we're about to overwrite the
    parameters with our fine-tuned checkpoint anyway, so the download
    is pure waste.

    `resolution` + `segmentation_head=True` MUST match the training
    configuration — they shape the model graph, and a mismatch silently
    loads wrong-shaped weights into the wrong slots.
    """
    model = RFDETRSegSmall(
        resolution=resolution,
        segmentation_head=True,
        pretrain_weights=None,
    )
    state = torch.load(checkpoint, map_location="cpu", weights_only=False)
    # rfdetr 1.4 quirk: even when fine-tuning with fewer classes, it
    # reinits the class head to match the pretrained COCO checkpoint's
    # 91-slot layout during Model.train. So our fine-tuned weights live
    # in a 91-slot head — fitted Fashionpedia IDs occupy the first 34
    # slots, the remainder is unused. Leave the default num_classes to
    # get a matching 91-slot head.
    inner = model.model.model
    if isinstance(state, dict) and "model" in state:
        inner.load_state_dict(state["model"])
    else:
        inner.load_state_dict(state)
    inner.eval()
    return model


def trace_to_jit(model: RFDETRSegSmall, resolution: int) -> torch.jit.ScriptModule:
    """Trace the model with a fixed-shape example input. Fixed shape is
    critical for Apple Neural Engine residency — dynamic inputs force
    CPU/GPU fallback.
    """
    inner = model.model.model
    inner = inner.cpu()
    inner.eval()
    # Switch LWDETR to its trace-friendly forward_export path, which
    # returns (bbox, class[, masks]) tuples instead of the training-time
    # NestedTensor dict that torch.jit.trace can't handle.
    inner.export()

    # Warmup forward pass. DETR positional embeddings that depend on
    # input resolution get computed lazily in some implementations; the
    # warmup locks them in so the subsequent trace captures a static
    # graph instead of the dynamic `upsample_bicubic2d` path.
    example = torch.rand(1, 3, resolution, resolution)
    with torch.no_grad():
        _ = inner(example)
        traced = torch.jit.trace(inner, example, strict=False)
    return traced


def convert_to_coreml(
    traced: torch.jit.ScriptModule,
    resolution: int,
) -> "ct.models.MLModel":
    """Convert the traced module to Core ML ML Program. Targets iOS 17 —
    matches the project's deployment floor and unlocks the newer ANE
    ops (fused attention, static k-v cache).
    """
    image_input = ct.ImageType(
        name="image",
        shape=(1, 3, resolution, resolution),
        scale=1.0 / 255.0,
        bias=[0.0, 0.0, 0.0],
    )
    # FLOAT32 avoids the automatic FP16 cast that introduces a rank-6
    # reshape on the deformable-attention `sampling_offsets` path, which
    # coremltools 8.1 rejects with "Core ML only supports rank <= 5".
    # We recover the size benefit via 6-bit palettization downstream.
    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT32,
    )
    return mlmodel


def rename_detr_outputs(mlmodel: "ct.models.MLModel") -> "ct.models.MLModel":
    """Rename coremltools' auto-generated output names (``var_XXXX``,
    ``linear_YYY``) to the stable DETR contract the iOS decoder probes for:

        pred_boxes   shape (1, n_queries, 4)
        pred_logits  shape (1, n_queries, num_classes)
        pred_masks   shape (1, n_queries, H, W)

    Identification is shape-based rather than name-based so this survives
    coremltools changing the autogen name scheme between versions.

    Why: `MultiGarmentProposalService.decodeDETROutput` looks up outputs by
    semantic name. Without this step the Swift side finds no outputs and
    returns an empty proposal list — the feature would silently no-op on
    every photo even though inference ran successfully.
    """
    spec = mlmodel.get_spec()
    rename_map: dict[str, str] = {}
    for out in spec.description.output:
        multi = out.type.multiArrayType
        shape = [int(s) for s in multi.shape]
        if len(shape) == 3 and shape[-1] == 4:
            rename_map[out.name] = "pred_boxes"
        elif len(shape) == 3:
            rename_map[out.name] = "pred_logits"
        elif len(shape) == 4:
            rename_map[out.name] = "pred_masks"

    if not rename_map:
        raise RuntimeError(
            "rename_detr_outputs: no DETR-shaped outputs found "
            f"in spec (outputs: {[o.name for o in spec.description.output]})"
        )

    for old, new in rename_map.items():
        rename_feature(spec, old, new, rename_inputs=False, rename_outputs=True)

    # Rebuild MLModel from the mutated spec. mlprogram keeps weights in a
    # side directory we must preserve.
    return MLModel(spec, weights_dir=mlmodel.weights_dir)


def palettize(mlmodel: "ct.models.MLModel") -> "ct.models.MLModel":
    """Apply 6-bit k-means palettization — matches the SAM2 compression
    recipe that's already shipping, so latency characteristics are
    predictable.
    """
    # per_tensor is iOS 16+ compatible; per_grouped_channel requires
    # iOS 18 (the app targets iOS 17.0, so per-grouped would lock out
    # the install base). 6-bit k-means per-tensor still nets ~4x weight
    # compression versus FP16.
    cfg = OpPalettizerConfig(
        nbits=6,
        mode="kmeans",
        granularity="per_tensor",
    )
    return palettize_weights(mlmodel, OptimizationConfig(global_config=cfg))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--checkpoint",
        type=Path,
        required=True,
        help="Path to best.pth from train.py",
    )
    p.add_argument(
        "--out",
        type=Path,
        default=Path("./checkpoints/coreml"),
        help="Output directory for .mlpackage files",
    )
    p.add_argument(
        "--resolution",
        type=int,
        default=1024,
        help="Input square resolution. MUST match training resolution.",
    )
    p.add_argument(
        "--no-palettize",
        action="store_true",
        help="Emit FP16 only (debug); ship artifact MUST be palettized.",
    )
    p.add_argument(
        "--copy-to-app",
        action="store_true",
        help="After palettization, copytree into "
        "WardrobeReDo/Models/CoreML/RFDETRSegFashion.mlpackage",
    )
    p.add_argument(
        "--app-root",
        type=Path,
        default=None,
        help="Override the default WardrobeReDo repo root (auto-detected "
        "as the grandparent of this script)",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    if not args.checkpoint.exists():
        print(f"FATAL: checkpoint {args.checkpoint} does not exist")
        return 1
    args.out.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("RF-DETR-Seg-Small → Core ML export")
    print("=" * 60)
    print(f"  checkpoint   {args.checkpoint}")
    print(f"  resolution   {args.resolution}")
    print(f"  out          {args.out}")
    print(f"  palettize    {'no' if args.no_palettize else 'yes (6-bit kmeans)'}")
    print()

    print("[1/4] loading checkpoint")
    model = _load_checkpoint(args.checkpoint, args.resolution)

    print("[2/4] torch.jit.trace")
    traced = trace_to_jit(model, args.resolution)

    print("[3/5] coremltools convert")
    mlmodel = convert_to_coreml(traced, args.resolution)

    print("[4/5] rename outputs → pred_boxes / pred_logits / pred_masks")
    mlmodel = rename_detr_outputs(mlmodel)
    fp16_path = args.out / "RFDETRSegFashion_fp16.mlpackage"
    mlmodel.save(str(fp16_path))
    print(f"  saved {fp16_path} "
          f"({sum(f.stat().st_size for f in fp16_path.rglob('*') if f.is_file()) / 1e6:.1f} MB)")

    if args.no_palettize:
        print("\nSkipping palettization (--no-palettize). Done.")
        return 0

    print("[5/5] 6-bit palettization")
    compressed = palettize(mlmodel)
    final_path = args.out / "RFDETRSegFashion.mlpackage"
    compressed.save(str(final_path))
    size_mb = sum(
        f.stat().st_size for f in final_path.rglob("*") if f.is_file()
    ) / 1e6
    print(f"  saved {final_path} ({size_mb:.1f} MB)")

    if size_mb > 100:
        print(
            f"\nWARNING: final model is {size_mb:.1f} MB (>100 MB). "
            "The plan's Background Assets delivery path (Section 9) may "
            "be required instead of bundling."
        )

    if args.copy_to_app:
        # Auto-detect repo root: scripts/ dir is two levels below the
        # Wardrobe Re-Do project root (notebooks/training/scripts/).
        app_root = args.app_root or Path(__file__).resolve().parents[3]
        dest = app_root / "WardrobeReDo" / "Models" / "CoreML" / "RFDETRSegFashion.mlpackage"
        print(f"\nCopying to {dest}")
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(final_path, dest)
        print(
            "Done. Run `xcodegen generate` + rebuild to pick up the new model.\n"
            "Then flip FeatureFlags.isMultiGarmentEnabled in Settings → Developer\n"
            "to verify on-device inference."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
