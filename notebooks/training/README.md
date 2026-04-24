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
| [`RUNPOD_RUNBOOK.md`](./RUNPOD_RUNBOOK.md) | **Copy-paste step-by-step for the \$30 RunPod training run.** Start here if you're about to burn GPU credit. |
| `scripts/probe_env.py` | Laptop-only env probe. Free. Run before spending \$ on a pod. |
| `scripts/prepare_fashionpedia.py` | CVDF download + filter to the 33 main apparel classes, emits rfdetr-compatible COCO dirs. |
| `scripts/train.py` | Production training CLI. Invoked on the GPU pod. |
| `scripts/export_coreml.py` | Trace + convert + 6-bit palettize + copy to app bundle. |
| `2026-04-multi-garment.ipynb` | Exploratory notebook. Same recipe, interactive form; the scripts above are authoritative for the actual training run. |
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
photos only.

The HF `detection-datasets/fashionpedia` mirror is **detection-only** —
it strips polygons. For RF-DETR-**Seg** training we need the CVDF S3
source, which `scripts/prepare_fashionpedia.py` pulls directly:

```bash
python notebooks/training/scripts/prepare_fashionpedia.py --out ./data/fashionpedia
# For smoke tests: add --max-train 500 --max-val 100
```

The script filters to the 33 main apparel classes, drops garment-parts
(sleeves, collars, etc.) and attributes, and emits Roboflow-style
`train/_annotations.coco.json` + `valid/_annotations.coco.json`.

## GPU

**Recommended — \$30 budget split across two RunPod pods:**
1. RTX 4090 24GB, community tier, ~3 hrs, ~\$2 — smoke-test the whole
   pipeline end-to-end on a 500-image subset.
2. H100 80GB, community tier, ~10 hrs, ~\$24 — production run on the
   full dataset at batch 8 / 1024².

H100 beats A100 40GB at this \$ because its DETR throughput is ~2–3×,
and 10 H100-hours is enough budget for 10 epochs at 1024². Full
copy-paste steps live in `RUNPOD_RUNBOOK.md`.

Alternative setups (Lambda, Vast.ai, local A100) work fine too — the
scripts don't care which provider. The runbook is RunPod-specific only
for pod boot instructions.

Original plan budget estimate: **~\$100–200** for a comfortable run.
\$30 gets a lean, minimum-viable model with one retry buffer.

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

As of 2026-04-18 the training run has not been executed. The Python
scripts are ready (`scripts/` is authoritative; notebook is
exploratory). The app ships behind a feature flag; when
`isMultiGarmentEnabled` is `false` (default) the absence of the
trained model is invisible to the user.

Commit 9 of the canonical plan flips the default to `true`; that commit
is blocked on `RUNPOD_RUNBOOK.md` producing a working `.mlpackage`.
