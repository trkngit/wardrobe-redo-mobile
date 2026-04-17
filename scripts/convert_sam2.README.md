# SAM2-tiny → Core ML conversion

`scripts/convert_sam2.py` turns Meta's PyTorch SAM2-tiny checkpoint into the
compiled `SAM2Tiny.mlmodelc` bundle that ships inside the iOS app. Runs
locally on an Apple-silicon Mac. Produces the file `SAM2Extractor` already
knows how to load — no Swift changes required.

This is a **one-shot owner task**. Everything the CI + repo cares about is
already in place; this script just fills in the missing binary.

## Why this is a separate script, not a CI step

1. Requires the Meta checkpoint (gated download, research license for the
   weights themselves — Meta has not approved redistribution via our CI).
2. Conversion is CPU-bound and takes ~10–15 min; not worth running on every
   push.
3. Output is a ~40 MB binary that belongs on Git LFS, not in the CI cache.

Run it once per SAM2 release. Commit the result. Done.

## Prerequisites

### 1. Python env (use a fresh venv)

```bash
python3.11 -m venv ~/.venvs/sam2-convert
source ~/.venvs/sam2-convert/bin/activate
pip install --upgrade pip
pip install "torch==2.7.0" "torchvision==0.22.0" "coremltools>=9.0" "Pillow" "scikit-learn"
pip install "git+https://github.com/facebookresearch/sam2.git"
```

Python 3.11 is the sweet spot. Two version pins matter:

- **`torch==2.7.0`.** `coremltools` 9.0 only tests against torch ≤ 2.7. Newer
  torch releases (2.8+) emit `aten::Int` nodes on shape destructures that
  coremltools' torch frontend can't fold, and the convert step dies with
  `TypeError: only 0-dimensional arrays can be converted to Python
  scalars`. Our script monkey-patches `_cast` to be tolerant, but staying
  on 2.7 avoids the whole class of regressions.
- **`scikit-learn`.** The 6-bit k-means palettization pass depends on it.
  coremltools imports it lazily, so forgetting it fails ~3 minutes into
  the run instead of at startup. The script's `check_environment()`
  fails-fast on this one now, but keep it in the install line.

### 2. Xcode command-line tools

```bash
xcode-select --install   # skip if `xcrun --version` already works
```

### 3. SAM2 checkpoint + config

The `sam2` pip install ships the YAML configs. The weights are a separate
download:

```bash
# Config (ships with the package)
python3 -c "import sam2, pathlib; print(pathlib.Path(sam2.__file__).parent / 'configs/sam2/sam2_hiera_t.yaml')"
# → /path/to/sam2/configs/sam2/sam2_hiera_t.yaml

# Checkpoint (pick the "tiny" row)
# https://github.com/facebookresearch/sam2#download-checkpoints
curl -L -o ~/Downloads/sam2_hiera_tiny.pt \
  https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_tiny.pt
```

The download URL above matches Meta's published checkpoint host as of the
2024-07-24 SAM2 release. If the link 404s, check the SAM2 README for the
current host.

## Run it

```bash
python3 scripts/convert_sam2.py \
    --checkpoint ~/Downloads/sam2_hiera_tiny.pt \
    --config    configs/sam2/sam2_hiera_t.yaml \
    --output    WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc
```

`--config` is a hydra-relative name (resolved against the `sam2` Python
package's `pkg://sam2` search path), not a filesystem path. If you ever
need to point at a fork of sam2, pass the absolute `.yaml` path instead
— the script translates it back to the package-relative form
automatically.

Expected output:

```
→ Building SAM2 from checkpoint…
→ Wrapping submodules into a traceable module…
→ Tracing and converting to Core ML (fp16)…
→ Compiling .mlpackage → .mlmodelc…

✓ Compiled model at: WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc
  size: ~30 MB
```

Typical wall time on an M-series MacBook: ~2 minutes end-to-end (tracing
+ MIL conversion + 6-bit k-means palettization + xcrun compile). The
palettization pass is the long tail — bigger models take longer.

### What the script does under the hood

1. Builds SAM2Base from the Meta checkpoint on CPU.
2. Monkey-patches Hiera's `_get_pos_embed` to **return a cached tensor
   from a pre-trace warmup pass**. Avoids coremltools' missing
   `upsample_bicubic2d` lowering and sidesteps trace-time tile-math
   ambiguities.
3. Wraps SAM2 into a traceable image-only module that skips the
   temporal memory path (we don't run video).
4. `torch.jit.trace` with an example `(image, point_coords, point_labels)`
   triple, then `ct.convert(..., compute_precision=FLOAT16,
   minimum_deployment_target=iOS17)`.
5. **Palettizes weights to 6-bit k-means** via
   `coremltools.optimize.coreml.palettize_weights`. This step is what
   gets the compiled bundle from ~80 MB (fp16, 39M params × 2 B) to
   ~30 MB (6-bit, 39M params × 0.75 B).
6. `xcrun coremlcompiler` bakes the `.mlpackage` into the runnable
   `.mlmodelc` bundle.

## Sanity-check before committing

```bash
# 1. Verify the compiled bundle has the expected input/output names.
xcrun coremlcompiler metadata WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc | head -40
# Look for:  inputs: image, point_coords, point_labels
#            outputs: masks

# 2. Confirm LFS is tracking it.
git lfs track "*.mlmodelc"   # no-op if already tracked (.gitattributes exists)
git lfs ls-files             # should list SAM2Tiny.mlmodelc after `git add`

# 3. Commit.
git add WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc .gitattributes
git commit -m "chore(model): add SAM2Tiny.mlmodelc (Apache-2.0)"
git push
```

Then on device: uninstall + reinstall the app. `SAM2Extractor.loadedModel`
should be non-nil on first call, and the "auto-cropped" badge should
appear for photos where Vision returned low confidence.

## When the conversion breaks

SAM2's Python API moves. If `torch.jit.trace` explodes or the resulting
model segfaults on device:

```bash
# Dump the current module tree and cross-check make_traceable() against it.
python3 scripts/convert_sam2.py \
    --checkpoint ~/Downloads/sam2_hiera_tiny.pt \
    --config    /path/to/sam2_hiera_t.yaml \
    --inspect
```

Output looks like:

```
SAM2 model class MRO:
  - sam2.modeling.sam2_base.SAM2Base
  - torch.nn.modules.module.Module
  - builtins.object

Top-level submodules:
  image_encoder: ImageEncoder
  memory_attention: MemoryAttention
  memory_encoder: MemoryEncoder
  sam_prompt_encoder: PromptEncoder
  sam_mask_decoder: MaskDecoder

Key attributes referenced by make_traceable():
  ✓ sam2.forward_image
  ✓ sam2._prepare_backbone_features
  ✓ sam2.sam_prompt_encoder
  ✓ sam2.sam_mask_decoder
  ✓ sam2.directly_add_no_mem_embed
  ✓ sam2.no_mem_embed
```

If any check mark flips to ✗, edit `make_traceable` in `convert_sam2.py`
to use the new attribute path. The wrapper is ~30 lines — fast to patch.

## License

The conversion script is our code — Apache-2.0, same as the rest of the
Wardrobe Re-Do repo. The output model inherits SAM2's Apache-2.0 license
(safe for App Store). Attribution text lives in
`Settings > About > Attributions` once the app UI lands.
