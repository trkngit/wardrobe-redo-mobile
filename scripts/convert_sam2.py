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
        # Pin torch to the last version coremltools 9.0 explicitly tests
        # against. Torch 2.11 emits aten::Int nodes that coremltools' torch
        # frontend trips on ("only 0-dimensional arrays…"); 2.7 avoids it.
        "torch": "torch==2.7.0",
        "coremltools": "coremltools>=9.0",
        "sam2": "git+https://github.com/facebookresearch/sam2.git",
        "PIL": "Pillow",
        # coremltools' k-means palettizer imports scikit-learn lazily — it
        # only complains at quantize time, which is after the 2-minute
        # trace + MIL conversion. Fail fast instead.
        "sklearn": "scikit-learn",
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

def resolve_hydra_config_name(config: Path) -> str:
    """Translate a filesystem path into the hydra-relative name sam2 expects.

    sam2.build_sam calls ``hydra.compose(config_name=config_file)`` against its
    own search path ``pkg://sam2``. That API wants a NAME relative to the sam2
    package (e.g. ``configs/sam2/sam2_hiera_t.yaml``), not an absolute
    filesystem path. Some sam2 releases silently strip the leading ``/`` and
    then fail with "Cannot find primary config 'Users/...'".

    Accept either form:
    * an absolute path under the installed sam2 package — translate it to a
      package-relative name.
    * a bare hydra name (e.g. ``configs/sam2/sam2_hiera_t.yaml``) — pass
      through unchanged.
    """
    import sam2 as _sam2_pkg

    sam2_root = Path(_sam2_pkg.__file__).resolve().parent
    config_resolved = config.expanduser()
    if config_resolved.is_absolute():
        try:
            rel = config_resolved.resolve().relative_to(sam2_root)
            return str(rel)
        except ValueError:
            # Path is absolute but not under the sam2 package. Fall through
            # and let sam2 raise its own MissingConfigException.
            return str(config_resolved)
    return str(config_resolved)


def build_sam2_model(checkpoint: Path, config: Path):
    """Load the SAM2 checkpoint on CPU. coremltools traces on CPU."""
    from sam2.build_sam import build_sam2

    config_name = resolve_hydra_config_name(config)
    model = build_sam2(config_name, str(checkpoint), device="cpu")
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

    # --- Hiera positional-embed patch --------------------------------------
    # Two problems with tracing `Hiera._get_pos_embed` straight:
    #
    # 1. It calls `F.interpolate(..., mode="bicubic")`. coremltools has no
    #    MIL lowering for `upsample_bicubic2d`.
    # 2. It tiles `pos_embed_window` by `[x // y for x, y in zip(...shape)]`,
    #    which produces 0-dim tensors under the tracer. coremltools then
    #    crashes trying to cast them with `int(x.val)` against a numpy
    #    multi-d array.
    #
    # Both issues vanish if we precompute the embedding *before* tracing,
    # since at a fixed `image_size` the forward pass always calls
    # `_get_pos_embed` with the same `(h, w)`. The pre-baked tensor is
    # captured as a graph constant, which every mainstream mobile-ViT port
    # (MobileSAM, EfficientSAM, Apple's Core ML ViT examples) does.
    trunk = sam2.image_encoder.trunk
    _orig_get_pos_embed = trunk._get_pos_embed

    # At image_size=1024 the Hiera patch-embed emits a 64×64 feature grid.
    # The backbone re-queries `_get_pos_embed` at every stage's spatial
    # size, so cache one Tensor per unique (h, w) pair.
    _pos_embed_cache: dict = {}

    def _cached_get_pos_embed(hw):
        key = (int(hw[0]), int(hw[1]))
        cached = _pos_embed_cache.get(key)
        if cached is None:
            with torch.no_grad():
                cached = _orig_get_pos_embed(key).detach()
            _pos_embed_cache[key] = cached
        return cached

    trunk._get_pos_embed = _cached_get_pos_embed

    # Warm the cache up-front by running a single dummy forward pass. We
    # run it on the same fixed-size input the tracer will see, so every
    # `_get_pos_embed((h, w))` the tracer calls hits the cache and returns
    # a precomputed tensor rather than going through bicubic interpolate.
    with torch.no_grad():
        _warmup = torch.zeros(1, 3, 1024, 1024, dtype=torch.float32)
        sam2.forward_image(_warmup)
    # ------------------------------------------------------------------------

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
            # NOTE: the trailing `[::-1]` is load-bearing — it restores
            # fine→coarse order after the zip reversed the inputs. Without
            # it, `feats[-1]` picks the FINEST map (256×256 @ image_size
            # 1024) instead of the coarsest (64×64), and the mask decoder
            # crashes with a shape mismatch against the prompt encoder's
            # 64×64 dense embedding. Mirrors upstream sam2's
            # SAM2ImagePredictor.set_image() exactly.
            feats = [
                feat.permute(1, 2, 0).view(1, -1, size[0], size[1])
                for feat, size in zip(vision_feats[::-1], feat_sizes[::-1])
            ][::-1]
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

def _patch_coremltools_cast() -> None:
    """Make coremltools' aten::Int / aten::Bool handler tolerate length-1
    ndarrays.

    Hiera's backbone destructures shape tuples (``B, H, W, C = x.shape``)
    and feeds the resulting 0-d scalar tensors into ``view()``/``reshape()``
    calls. PyTorch's jit tracer serialises each shape read as an
    ``aten::Int`` node, and coremltools' folder tries to reduce it to a
    compile-time constant with ``int(x.val)``. When ``x.val`` is a numpy
    array of shape ``(1,)`` (not a true 0-d scalar), NumPy 2.x refuses the
    implicit cast with ``TypeError: only 0-dimensional arrays can be
    converted to Python scalars``.

    The fix is a one-liner: use ``.item()`` on length-1 arrays before
    casting. We monkey-patch rather than edit the site-package so the
    script stays self-contained.
    """
    import numpy as np
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops as _torch_ops

    _orig_cast = _torch_ops._cast

    def _cast_tolerant(context, node, dtype, dtype_name):
        inputs = _torch_ops._get_inputs(context, node, expected=1)
        x = inputs[0]
        if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
            raise ValueError("input to cast must be either a scalar or a length 1 tensor")

        if x.can_be_folded_to_const():
            val = x.val
            # Normalise length-1 ndarrays to a Python scalar before the
            # dtype cast — `int(np.array([3]))` raises in NumPy 2.x, but
            # `int(np.array([3]).item())` is always fine.
            if isinstance(val, np.ndarray):
                val = val.item() if val.size == 1 else val.reshape(()).item()
            if not isinstance(val, dtype):
                res = mb.const(val=dtype(val), name=node.name)
            else:
                res = mb.const(val=val, name=node.name)
        elif len(x.shape) > 0:
            x2 = mb.squeeze(x=x, name=node.name + "_item")
            res = mb.cast(x=x2, dtype=dtype_name, name=node.name)
        else:
            res = mb.cast(x=x, dtype=dtype_name, name=node.name)
        context.add(res, node.name)

    _torch_ops._cast = _cast_tolerant


def convert(traced_module, image_size: int, max_points: int, out_mlpackage: Path) -> None:
    import coremltools as ct
    import torch

    _patch_coremltools_cast()

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

    # fp16 alone lands the compiled bundle at ~80 MB for SAM2-tiny
    # (~39M params × 2 bytes). The plan budgets ≤ 50 MB for the
    # `.mlmodelc`. Palettize weights to 6-bit, which drops storage to
    # ~0.75 bytes/param ≈ 29 MB and preserves mask IoU within ~1 pp on
    # published SAM-family benchmarks.
    from coremltools.optimize.coreml import (
        OpPalettizerConfig,
        OptimizationConfig,
        palettize_weights,
    )

    palette_cfg = OptimizationConfig(
        global_config=OpPalettizerConfig(mode="kmeans", nbits=6)
    )
    mlmodel = palettize_weights(mlmodel, config=palette_cfg)

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
    # `--config` may be either an absolute path to the .yaml on disk OR a bare
    # hydra-relative name (e.g. `configs/sam2/sam2_hiera_t.yaml`). Only reject
    # the former if the file is missing; bare names resolve inside sam2's
    # `pkg://sam2` search path and never exist on the local filesystem as-is.
    if args.config.expanduser().is_absolute() and not args.config.expanduser().exists():
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
