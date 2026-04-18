# Multi-Garment Detection — Training

Reproducibility harness for fine-tuning RF-DETR-Seg-Small on Fashionpedia
and converting the result to a Core ML `.mlpackage` that ships behind the
`FeatureFlags.isMultiGarmentEnabled` gate.

The runtime iOS pipeline (behind the flag) is already merged. This folder
is what turns the placeholder into a model that actually detects
garments.

## Contents

| File | Purpose |
|------|---------|
| `2026-04-multi-garment.ipynb` | End-to-end training + Core ML export notebook |
| `requirements.txt` | Pinned Python dependencies (run exactly once to reproduce the environment) |
| `README.md` | This document |

## Canonical plan

The architectural decisions, license research, and risk analysis behind
this training run live in
[`docs/plans/2026-04-18-multi-garment-detection.md`](../../docs/plans/2026-04-18-multi-garment-detection.md).
Read that first — this README only covers the mechanics of re-running
the notebook.

## One-time environment setup

```bash
# From repo root
python3.11 -m venv .venv-train
source .venv-train/bin/activate
pip install -r notebooks/training/requirements.txt
```

Python 3.11 is pinned because RF-DETR's dependencies (timm, torch) have
dropped 3.10 support and 3.12 is still ahead of coremltools' tested
matrix.

## Dataset

Fashionpedia annotations are [CC BY 4.0](https://fashionpedia.github.io/home/data_license.html).
The CVDF image mirror is commercial-use safe; we filter to CC-licensed
photos only. Prep via:

```bash
# The notebook has a one-shot cell that does this for you, but the
# commands are documented here so you can sanity-check them.
mkdir -p data/fashionpedia
wget -P data/fashionpedia https://huggingface.co/datasets/detection-datasets/fashionpedia/resolve/main/train.zip
wget -P data/fashionpedia https://huggingface.co/datasets/detection-datasets/fashionpedia/resolve/main/val.zip
```

## GPU

A single NVIDIA A100 40GB or equivalent is sufficient. The notebook is
parameterized on `device`, `batch_size`, and `image_size`; defaults are
tuned for an A100 but can be dialed down for an RTX 4090 / T4.

Budget for one full training cycle: **~$100-200** on Lambda Labs or
Vast.ai interruptible.

## Outputs

After the notebook finishes:

```
checkpoints/
  RFDETRSegFashion_best.pth        # selected by val mAP
  RFDETRSegFashion_epoch_N.pth     # all training snapshots

WardrobeReDo/Models/CoreML/
  RFDETRSegFashion.mlpackage       # 6-bit palettized, ~30-50 MB
```

Drop the `.mlpackage` into `WardrobeReDo/Models/CoreML/` (already
excluded from Xcode source control but referenced by the Resources
build phase via `xcodegen`); run `xcodegen generate`; rebuild.

## Status

As of 2026-04-18 the notebook is a **scaffold** — it describes the
training recipe and exports to Core ML, but the GPU run has not been
executed. The app ships behind a feature flag; when `isMultiGarmentEnabled`
is `false` (default) the absence of the trained model is invisible to
the user.

Commit 9 of the canonical plan flips the default to `true`; that commit
is blocked on this notebook producing a working `.mlpackage`.
