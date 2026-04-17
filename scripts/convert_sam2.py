#!/usr/bin/env python3
"""convert_sam2.py — one-shot converter from SAM2-tiny PyTorch → Core ML.

Builds the SAM2-tiny model from Meta's checkpoint + config, traces the
image encoder + prompt encoder + mask decoder as a single forward pass,
converts to an ML Program with fp16 weights, compiles to `.mlmodelc`, and
drops the result at the iOS bundle path the Swift code expects.

The iOS loader (`WardrobeReDo/Services/Extraction/SAM2Extractor.swift`)
looks for input names `image`, `point_coords`, `point_labels` and an
output named `masks`, with flexible fallbacks. This script produces those
names exactly so the Swift code binds without extra work.

Usage:
    python3 scripts/convert_sam2.py \\
        --checkpoint ~/Downloads/sam2_hiera_tiny.pt \\
        --config    ~/sam2/sam2/configs/sam2/sam2_hiera_t.yaml \\
        --output    WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc

Run with `--inspect` to dump the loaded model's submodule tree without
tracing — useful when a new `sam2` release has renamed something under
`SAM2Base` and the trace body below needs an update.

See `scripts/convert_sam2.README.md` for the full recipe: env setup,
where to download the checkpoint, and the LFS commit step.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--checkpoint",
        type=Path,
        required=True,
        help="Path to sam2_hiera_tiny.pt (download from the Meta SAM2 repo).",
    )
    parser.add_argument(
        "--config",
        type=Path,
        required=True,
        help="Path to sam2_hiera_t.yaml (shipped with the sam2 Python package).",
    )
    parser.add_argument(
        "--image-size",
        type=int,
        default=1024,
        help="Model input resolution (default 1024 — SAM2's native training size).",
    )
    parser.add_argument(
        "--max-points",
        type=int,
        default=16,
        help="Max tap points the compiled model will accept (default 16).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc"),
        help="Destination for the compiled .mlmodelc bundle.",
    )
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="Load the SAM2 model and print its structure, then exit. No tracing.",
    )
    parser.add_argument(
        "--keep-intermediate",
        action="store_true",
        help="Keep the uncompiled .mlpackage next to the .mlmodelc for debugging.",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

def check_environment() -> None:
    """Fail fast if the Python env or xcrun aren't ready.

    Prints the exact pip commands needed so the owner doesn't have to
    reverse-engineer a requirements.txt that we intentionally don't
    commit (this is a dev-only tool).
    """
    required = {
        "torch": "torch>=2.1",
        "coremltools": "coremltools>=7.2",
        "sam2": "git+https://github.com/facebookresearch/sam2.git",
        "PIL": "Pillow",
    }
    missing: list[tuple[str, str]] = []
    for name, spec in required.items():
        try:
            __import__(name)
        except ImportError:
            missing.append((name, spec))
    if missing:
        sys.stderr.write("Missing Python packages. Install with:\n")
        for name, spec in missing:
            sys.stderr.write(f"  pip install {spec!r}\n")
        sys.stderr.write(
            "\nRecommended: a dedicated venv on Python 3.11 to avoid torch "
            "pinning churn in your default interpreter.\n"
        )
        sys.exit(2)

    if shutil.which("xcrun") is None:
        sys.stderr.write(
            "xcrun not found. This script needs Xcode command-line tools "
            "to compile .mlpackage → .mlmodelc.\n"
            "Install: xcode-select --install\n"
        )
        sys.exit(2)


# ---------------------------------------------------------------------------
# Model loading + wrapping
# ---------------------------------------------------------------------------

def build_sam2_model(checkpoint: Path, config: Path):
    """Load the SAM2 checkpoint on CPU. coremltools traces on CPU."""
    from sam2.build_sam import build_sam2

    model = build_sam2(str(config), str(checkpoint), device="cpu")
    model.eval()
    return model


def make_traceable(sam2):
    """Flatten SAM2's video-capable forward pass into a single image call.

    The unwrapped SAM2Base carries per-frame memory (attention over past
    frames, temporal features). For one-shot image segmentation we drop
    all that and call the three core submodules directly, substituting
    the learned "no memory" embedding where the video path would use
    actual frame memory.

    If any of the attribute paths (`forward_image`,
    `_prepare_backbone_features`, `sam_prompt_encoder`, `sam_mask_decoder`,
    `directly_add_no_mem_embed`, `no_mem_embed`) stop matching the sam2
    release you installed, run this script with `--inspect` to print the
    current module tree and adjust the forward body below.
    """
    import torch
    import torch.nn.functional as F

    class TraceableSAM2(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, image, point_coords, point_labels):
            # 1. Hiera backbone + FPN neck → multi-scale feature maps.
            backbone_out = self.inner.forward_image(image)
            _, vision_feats, _, feat_sizes = (
                self.inner._prepare_backbone_features(backbone_out)
            )

            # SAM2 injects a learned "no memory" token in image-only mode
            # so the temporal path sees a well-formed input. Skipping this
            # step produces garbage masks.
            if self.inner.directly_add_no_mem_embed:
                vision_feats[-1] = vision_feats[-1] + self.inner.no_mem_embed

            # The mask decoder wants feature maps in (B, C, H, W) form.
            # SAM2's internal features are (HW, B, C); reshape back.
            feats = [
                feat.permute(1, 2, 0).view(1, -1, size[0], size[1])
                for feat, size in zip(vision_feats[::-1], feat_sizes[::-1])
            ]
            image_embeddings = feats[-1]
            high_res_features = feats[:-1]

            # 2. Prompt encoder — each click becomes a sparse token.
            sparse_pe, dense_pe = self.inner.sam_prompt_encoder(
                points=(point_coords, point_labels),
                boxes=None,
                masks=None,
            )

            # 3. Mask decoder — mask logits at input/4 resolution.
            low_res_masks, _, _, _ = self.inner.sam_mask_decoder(
                image_embeddings=image_embeddings,
                image_pe=self.inner.sam_prompt_encoder.get_dense_pe(),
                sparse_prompt_embeddings=sparse_pe,
                dense_prompt_embeddings=dense_pe,
                multimask_output=False,
                repeat_image=False,
                high_res_features=high_res_features,
            )

            # 4. Upsample so the iOS side doesn't need to know about 1/4 res.
            height, width = image.shape[-2:]
            return F.interpolate(
                low_res_masks,
                size=(height, width),
                mode="bilinear",
                align_corners=False,
            )

    return TraceableSAM2(sam2)


# ---------------------------------------------------------------------------
# Trace + convert
# ---------------------------------------------------------------------------

def convert(traced_module, image_size: int, max_points: int, out_mlpackage: Path) -> None:
    import coremltools as ct
    import torch

    example_image = torch.zeros(1, 3, image_size, image_size, dtype=torch.float32)
    example_coords = torch.full((1, 1, 2), image_size / 2.0, dtype=torch.float32)
    example_labels = torch.ones((1, 1), dtype=torch.float32)

    traced_module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(
            traced_module,
            (example_image, example_coords, example_labels),
            strict=False,
        )

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, image_size, image_size),
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            ),
            ct.TensorType(
                name="point_coords",
                shape=(1, ct.RangeDim(1, max_points), 2),
            ),
            ct.TensorType(
                name="point_labels",
                shape=(1, ct.RangeDim(1, max_points)),
            ),
        ],
        outputs=[ct.TensorType(name="masks")],
    )
    mlmodel.short_description = (
        "SAM2-tiny clothing segmentation (Wardrobe Re-Do). "
        "Inputs: image (RGB), point_coords (pixel-space), point_labels (1=positive, 0=negative). "
        "Output: sigmoid-logit mask at input resolution."
    )
    mlmodel.version = "1.0"
    mlmodel.save(str(out_mlpackage))


def compile_to_mlmodelc(mlpackage: Path, staging_dir: Path) -> Path:
    """Compile `.mlpackage` → `.mlmodelc` via xcrun."""
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(mlpackage), str(staging_dir)],
        check=True,
    )
    return staging_dir / f"{mlpackage.stem}.mlmodelc"


def inspect(sam2) -> None:
    """Dump the loaded model's class hierarchy + submodules.

    Use when a new sam2 release breaks `make_traceable` — the print
    output tells you which attribute names to reach for in the forward
    body, without having to clone the upstream repo and grep.
    """
    print("SAM2 model class MRO:")
    for cls in type(sam2).__mro__:
        print(f"  - {cls.__module__}.{cls.__qualname__}")
    print("\nTop-level submodules:")
    for name, mod in sam2.named_children():
        print(f"  {name}: {type(mod).__qualname__}")
    print("\nKey attributes referenced by make_traceable():")
    for attr in (
        "forward_image",
        "_prepare_backbone_features",
        "sam_prompt_encoder",
        "sam_mask_decoder",
        "directly_add_no_mem_embed",
        "no_mem_embed",
    ):
        present = hasattr(sam2, attr)
        marker = "✓" if present else "✗"
        print(f"  {marker} sam2.{attr}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def dir_size_bytes(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    args = parse_args()
    check_environment()

    if not args.checkpoint.exists():
        sys.exit(f"Checkpoint not found: {args.checkpoint}")
    if not args.config.exists():
        sys.exit(f"Config not found: {args.config}")

    print("→ Building SAM2 from checkpoint…")
    sam2 = build_sam2_model(args.checkpoint, args.config)

    if args.inspect:
        inspect(sam2)
        return 0

    print("→ Wrapping submodules into a traceable module…")
    traceable = make_traceable(sam2)

    args.output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp_str:
        tmp = Path(tmp_str)
        stem = args.output.stem  # "SAM2Tiny"
        mlpackage = tmp / f"{stem}.mlpackage"

        print("→ Tracing and converting to Core ML (fp16)…")
        convert(traceable, args.image_size, args.max_points, mlpackage)

        print("→ Compiling .mlpackage → .mlmodelc…")
        compiled = compile_to_mlmodelc(mlpackage, tmp)

        if args.output.exists():
            shutil.rmtree(args.output)
        shutil.copytree(compiled, args.output)

        if args.keep_intermediate:
            sibling = args.output.with_suffix(".mlpackage")
            if sibling.exists():
                shutil.rmtree(sibling)
            shutil.copytree(mlpackage, sibling)

    size_mb = dir_size_bytes(args.output) / 1_000_000
    print(f"\n✓ Compiled model at: {args.output}")
    print(f"  size: {size_mb:.1f} MB")
    print("")
    print("Next steps:")
    print("  1. Verify Git LFS tracks *.mlmodelc: git lfs ls-files")
    print(f"  2. Stage the model:       git add {args.output}")
    print( "  3. Commit:                git commit -m 'chore(model): add SAM2Tiny.mlmodelc'")
    print( "  4. Push with LFS:         git push")
    print( "  5. On first device build, confirm SAM2Extractor loads the model")
    print( "     (Vision-only fallback stops firing for low-confidence photos).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
