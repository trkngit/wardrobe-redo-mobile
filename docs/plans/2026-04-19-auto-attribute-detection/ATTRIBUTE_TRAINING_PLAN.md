# Attribute Classifier — Training Plan (Option C, fit-only)

> **Phase:** 2 (this doc) → 3 (training) → 4 (export + iOS wiring)
> **Parent plan:** [../2026-04-19-auto-attribute-detection.md](../2026-04-19-auto-attribute-detection.md)
> **Scope lock:** [ATTRIBUTE_TAXONOMY.md § Section 0](./ATTRIBUTE_TAXONOMY.md) — Option C
> **Blocker register:** [BLOCKERS.md](./BLOCKERS.md)
> **Authored:** 2026-04-19

This document is the handoff between the dataset preparer (Phase 2,
shipped) and the single-head MobileNetV3-Small fit classifier (Phase 3,
pod-dependent). Anyone picking up training should be able to read this
doc + `manifest.csv` + `manifest_meta.json` and start a run without
re-deriving the scope.

---

## Table of contents

- [1 · Dataset (Option C)](#1--dataset-option-c)
- [2 · Class distribution & imbalance](#2--class-distribution--imbalance)
- [3 · Preparer contract](#3--preparer-contract)
- [4 · Phase 3 model spec](#4--phase-3-model-spec)
- [5 · Target metrics](#5--target-metrics)
- [6 · Phase 4 export + iOS decode](#6--phase-4-export--ios-decode)
- [7 · Pod runbook](#7--pod-runbook)
- [8 · Failure modes & fallbacks](#8--failure-modes--fallbacks)

---

## 1 · Dataset (Option C)

**Source:** Fashionpedia v2 (CC BY 4.0) — `instances_attributes_{train,val}2020.json` + `train2020.zip` + `val_test2020.zip`. Pre-downloaded by
[notebooks/training/scripts/prepare_fashionpedia.py](../../../notebooks/training/scripts/prepare_fashionpedia.py) into `./data/fashionpedia/_raw/`.

**Labels emitted:** `FitAttribute.rawValue` for 5 of 6 iOS enum cases.
`structured` is NOT trained (no Fashionpedia signal — see [BLOCKERS.md#D-6](./BLOCKERS.md#d-6--fitattributestructured-has-no-fashionpedia-signal)).
Texture is NOT trained in v1 (see [ATTRIBUTE_TAXONOMY.md § Section 0](./ATTRIBUTE_TAXONOMY.md)).

| idx | label      | Fashionpedia source                                   |
| --- | ---------- | ----------------------------------------------------- |
| 0   | oversized  | attr 138 oversized                                    |
| 1   | relaxed    | attr 137 loose (fit)                                  |
| 2   | regular    | attr 136 regular (fit)                                |
| 3   | slim       | attr 135 tight (fit)                                  |
| 4   | cropped    | attr 146 above-the-hip (length) — gated to top-like   |

Index order is authoritative: `TRAINABLE_FIT_LABELS` in
[fashionpedia_attr_to_ios_enum.py:209](../../../notebooks/training/scripts/fashionpedia_attr_to_ios_enum.py). The Core ML export (Phase 4) writes labels
into `AttributeClassifier.mlpackage` metadata in this order, and the
iOS decode (
[AttributeClassifierService.swift](../../../WardrobeReDo/Services/Extraction/AttributeClassifierService.swift)
) reads `fitLabels` in the same order. Any reordering is a cross-layer
break.

**Tie-break rules** (handled by `resolve_fit_label` — see
[BLOCKERS.md#P2-1](./BLOCKERS.md#p2-1--fitattributecropped-leaks-to-non-tops-without-gating) and [#P2-2](./BLOCKERS.md#p2-2--multi-attribute-annotations-need-a-tie-break)):

- attr 146 (cropped) on a non-top category → dropped silently (hem
  length signal is irrelevant for skirts / dresses / bottoms).
- multi-snugness (e.g. both 135 and 137) → annotation dropped as
  ambiguous (~1–2% of crops).
- attr 146 + any of {135, 136, 137} → label = cropped (more specific
  wins; the dropped snugness signal is usually regular anyway).

## 2 · Class distribution & imbalance

Expected counts **before bbox filtering** (from
[fashionpedia_attribute_inventory.csv](./fashionpedia_attribute_inventory.csv) — full train audit):

| label     | annotations | share | imbalance vs regular |
| --------- | ----------- | ----- | -------------------- |
| regular   | 24,669      | 41.0% | 1.0×                 |
| cropped   | 17,444      | 29.0% | 1.4× (post-gating drops ~30%; effective ≈12k) |
| slim      | 13,473      | 22.4% | 1.8×                 |
| relaxed   | 4,990       | 8.3%  | 4.9×                 |
| oversized | 670         | 1.1%  | **36.8×**            |

Post-preparer (after P2-1 gating, P2-2 dual-fit drops, P2-5 bbox filter
and aspect drops) the expected surviving corpus is **≈55k train crops
+ ≈8k val crops**. The exact counts ship in `manifest_meta.json` under
`class_counts_by_split` so Phase 3 can pull them without a second scan.

**Training implication ([BLOCKERS.md#P2-3](./BLOCKERS.md#p2-3--371-class-imbalance-regular-vs-oversized)):**

- Class-weighted cross-entropy with
  `weight[c] = clip(max_count / class_count[c], 1.0, 10.0)`.
- Or equivalently: `WeightedRandomSampler` with per-sample probability
  ∝ `1 / class_count[label]`.
- Clamp prevents oversized from dominating the gradient (its 37× raw
  weight would fit to noise).

## 3 · Preparer contract

**Script:** [prepare_attribute_dataset.py](../../../notebooks/training/scripts/prepare_attribute_dataset.py).
**Run scope:** train split + val split. No test split emitted (Phase 9
dogfood covers real-world evaluation).

**Output layout under `--out <dir>`:**

```
<out>/
├── train/<annotation_id>.jpg     # 224×224, RGB, neutral-gray pad
├── val/<annotation_id>.jpg
├── manifest.csv
└── manifest_meta.json
```

**manifest.csv schema** (one row per surviving annotation):

| column           | type | notes                                                |
| ---------------- | ---- | ---------------------------------------------------- |
| split            | str  | `"train"` or `"val"`                                 |
| image_path       | str  | **relative** to `<out>` — portable across local / pod ([P2-7](./BLOCKERS.md#p2-7--image-paths-must-be-portable-local-smoke--pod-run)) |
| annotation_id    | int  | Fashionpedia `annotations[i].id` (for traceability)  |
| image_id         | int  | Fashionpedia `annotations[i].image_id`               |
| main_class       | str  | Normalized via `normalize_class_name` ([P2-6](./BLOCKERS.md#p2-6--fashionpedia-category-name-casing--punctuation)) |
| fit_label_name   | str  | `FitAttribute.rawValue` — one of the 5              |
| fit_label_idx    | int  | Index into `TRAINABLE_FIT_LABELS` (argmax target)    |
| bbox_w / bbox_h  | int  | Source bbox pixels BEFORE padding (debug aid)        |

**manifest_meta.json shape:**

```json
{
  "scope": "Option C (fit-only, single-head)",
  "labels": ["oversized", "relaxed", "regular", "slim", "cropped"],
  "total_crops": 63284,
  "class_counts_by_split": {
    "train": { "regular": 24000, "cropped": 11800, "slim": 13100, "relaxed": 4800, "oversized": 640 },
    "val":   { "regular":  3100, "cropped":  1520, "slim":  1690, "relaxed":  620, "oversized":  82 }
  },
  "class_counts_total": { "regular": 27100, "cropped": 13320, "slim": 14790, "relaxed": 5420, "oversized": 722 },
  "filter_constants": {
    "crop_size": 224,
    "min_area_fraction": 0.02,
    "max_aspect_ratio": 4.0,
    "pad_color": [128, 128, 128]
  }
}
```

Numbers above are order-of-magnitude estimates — trust the real file
after the pod run.

**Idempotence:** the preparer skips crops whose destination file
already exists and is non-empty. Re-running after a partial ctrl-C
resumes without re-encoding. The manifest is always rewritten from
scratch — if you edit the preparer, rerun the full script, don't
append.

**Filter stats:** every `process_split` call prints `dropped X clamp +
Y filter + Z decode + W write`. Put those lines into the Phase 3
launch log; they're the fastest sanity check that the preparer ran
against the right data.

## 4 · Phase 3 model spec

**Script (to write):** `notebooks/training/scripts/train_attributes.py`.

**Architecture (single-head, per [BLOCKERS.md#D-2](./BLOCKERS.md#d-2--phase-3-train_attributespy-must-be-single-head)):**

```python
# pseudo-spec, exact args TBD during implementation
timm.create_model(
    "mobilenetv3_small_100",
    pretrained=True,
    num_classes=5,  # TRAINABLE_FIT_LABELS
)
```

- Input: 224×224 RGB (matches preparer's crop size).
- ImageNet-pretrained backbone; replace final classifier with
  `Linear(in_features=1024, out_features=5)`.
- No texture head. Do not emit `texture_logits`.

**Training hyperparameters (starting point, tune from the smoke run):**

| param          | value                                       |
| -------------- | ------------------------------------------- |
| optimizer      | AdamW, lr=3e-4, weight_decay=1e-4           |
| schedule       | cosine, warmup 1 epoch                      |
| epochs         | 20                                          |
| batch size     | 128                                         |
| augmentations  | random horizontal flip, mild color jitter, `RandomErasing(p=0.25)` |
| loss           | `CrossEntropyLoss(weight=class_weights)` where `class_weights = clip(max / counts, 1.0, 10.0)` |
| input stats    | ImageNet mean/std: `(0.485, 0.456, 0.406)` / `(0.229, 0.224, 0.225)` |

**Sampling:** `WeightedRandomSampler` over the training manifest so
each batch oversamples the rare classes (oversized, relaxed). Val stays
uniform so reported accuracy is honest.

**Checkpoints:**

- `attr_last.pth` — every epoch.
- `attr_best.pth` — best val macro-F1 (NOT accuracy; accuracy is
  gamed by the `regular` majority).
- `attr_metrics.json` — per-epoch train/val loss + per-class
  precision/recall/F1 + confusion matrix.

**Eval (`eval_attributes.py`):**

- Confusion matrix across 5 classes.
- Per-class precision/recall/F1 table.
- Calibration plot: bucket predictions by confidence 0.0…1.0 in
  0.05-wide bins, measure realized accuracy per bucket. **This is the
  sanity check on the 0.80 pre-fill threshold** — we need the
  confidence-≥0.80 bucket to land at ≥90% realized accuracy before
  flipping the `isAttributeDetectionEnabled` flag.

## 5 · Target metrics

Metric floors for Phase 3 to be considered shippable:

| metric                         | floor | stretch | why                                        |
| ------------------------------ | ----- | ------- | ------------------------------------------ |
| val top-1 accuracy             | 0.75  | 0.82    | majority baseline is ~0.41 (always-regular) |
| val macro-F1 (5-class)         | 0.55  | 0.68    | guards against rare-class collapse         |
| per-class F1 (oversized)       | 0.30  | 0.55    | 670-ann class — acknowledged stretch       |
| per-class F1 (relaxed)         | 0.45  | 0.65    | 4,990-ann, second-rarest                   |
| calibration @ conf≥0.80        | 0.90  | 0.95    | underwrites the pre-fill threshold         |

If oversized F1 falls below 0.20, drop it from `TRAINABLE_FIT_LABELS`
and retrain as 4-class; document the decision in BLOCKERS.md as a new
entry (do NOT silently collapse classes without updating the iOS
side).

## 6 · Phase 4 export + iOS decode

**Export (`export_attribute_classifier.py`, to write):**

1. Load `attr_best.pth`.
2. `torch.jit.trace` with a random `(1, 3, 224, 224)` Float32 tensor.
3. `coremltools.convert(traced, ...)` with:
   - `inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1/255, bias=[-0.485/0.229, -0.456/0.224, -0.406/0.225])]`
     (or equivalent normalization).
   - `outputs=[ct.TensorType(name="fit_probs")]` (softmax, 5-dim).
   - **Do NOT emit `texture_probs`** — Option C single-head.
4. 6-bit k-means palettization (reuse the helper in
   `notebooks/training/scripts/export_coreml.py`).
5. Ship to `WardrobeReDo/ML/AttributeClassifier.mlpackage`.

**iOS decode contract (already wired in
[AttributeClassifierService.swift](../../../WardrobeReDo/Services/Extraction/AttributeClassifierService.swift)):**

- `multiArray(for: fitOutputKeys, ...)` returns the 5-dim softmax.
- `argmaxSoftmax` → `(fitLabel, fitConfidence)`.
- `multiArray(for: textureOutputKeys, ...)` returns **nil** (the
  single-head mlpackage has no such output). The existing
  nil-tolerant path produces `(texture: nil, textureConfidence: 0.0)`
  — correct Option C behavior.
- **Regression test to add ([BLOCKERS.md#D-3](./BLOCKERS.md#d-3--phase-4-real-mlpackage-decode-must-handle-missing-texture-outputs)):** feed a fake
  `MLFeatureProvider` that only exposes `fit_probs`; assert
  `decode(prediction:)` returns `texture == nil` and does not throw.

## 7 · Pod runbook

```bash
# On the training pod (RF-DETR-Seg has already finished; reuse the
# same environment).
cd /workspace/wardrobe

# 1. Ensure raw Fashionpedia is local. If not, run:
./notebooks/training/scripts/prepare_fashionpedia.py  # ~12 GB, 20 min

# 2. Build the attribute dataset. Expected ≈8 min wall-clock on an
#    NVMe pod disk; bulk of time is JPEG re-encoding.
./.venv-train/bin/python notebooks/training/scripts/prepare_attribute_dataset.py \
    --out /workspace/training/attr-dataset \
    --annotations-dir /workspace/fashionpedia/_raw \
    --images-dir /workspace/fashionpedia/_raw

# Sanity-check the outputs before queueing training:
jq '.total_crops, .class_counts_total' /workspace/training/attr-dataset/manifest_meta.json
wc -l /workspace/training/attr-dataset/manifest.csv

# 3. Phase 3: launch training (when train_attributes.py ships).
./.venv-train/bin/python notebooks/training/scripts/train_attributes.py \
    --dataset-root /workspace/training/attr-dataset \
    --out /workspace/training/attr-runs/$(date +%Y%m%d-%H%M)

# 4. Phase 4: export.
./.venv-train/bin/python notebooks/training/scripts/export_attribute_classifier.py \
    --checkpoint /workspace/training/attr-runs/.../attr_best.pth \
    --out /workspace/training/AttributeClassifier.mlpackage
```

**Local smoke (laptop, CPU-only):**

```bash
./.venv-train/bin/python notebooks/training/scripts/prepare_attribute_dataset.py \
    --out ./data/attr-dataset \
    --max-train 500 --max-val 100

./.venv-train/bin/python notebooks/training/scripts/test_prepare_attribute_dataset.py
```

The test harness uses a synthetic in-memory Fashionpedia JSON + zip —
it does NOT require the 12 GB download. All 11 test groups currently
pass (verified 2026-04-19).

## 8 · Failure modes & fallbacks

| symptom                                              | likely cause                                        | fallback                                             |
| ---------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------- |
| `manifest_meta.total_crops < 40000`                  | P2-5 filters too aggressive, or zip missing images  | Bump `MIN_AREA_FRACTION` down to 0.015; re-audit filter stats |
| oversized class has <400 surviving crops             | Rare. Means attr 138 annotations are mostly on mini-crops that the bbox filter is nuking | Allow oversized to bypass `MIN_AREA_FRACTION` (rare-class carve-out) |
| val macro-F1 stuck at 0.40                           | Model collapsed to "always regular"                 | Double the class weights (clamp at 20 not 10); or switch to focal loss γ=2 |
| calibration at conf≥0.80 below 0.85                  | Overfit or miscalibrated softmax                    | Add label smoothing (0.05); longer cosine schedule; more aug |
| oversized F1 < 0.20                                  | 670 anns genuinely insufficient                     | Retrain as 4-class; update `TRAINABLE_FIT_LABELS`; flag in BLOCKERS |
| preparer `dropped N filter` exceeds 15% of corpus    | Aspect-ratio filter too tight for skirts / dresses  | Log the rejected class histogram; consider lifting MAX_ASPECT to 5.0 and re-running |

If any of these fire, stop training and update BLOCKERS.md with a new
entry before iterating — the whole point of Option C's conservative
scope is that surprises mean a taxonomy problem, not a model problem.

## Next action

Phase 3: write `train_attributes.py` + `eval_attributes.py` against
the manifest schema in § 3 above. Blocked on the pod run that produces
`/workspace/training/attr-dataset/manifest_meta.json` — kick that off
first so hyperparameter choices can cite real class counts instead of
the estimates in § 2.
