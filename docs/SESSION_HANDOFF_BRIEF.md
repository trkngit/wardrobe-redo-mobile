# Wardrobe Re-Do — Session Handoff Brief

> **Generated:** 2026-04-22
> **Head commit:** `d4ac188` on `feature/photo-extraction-engine` (75 commits ahead of `main`)
> **Purpose:** Complete context for resuming work in a fresh Claude Code session. Scattered context lives in 4 old sessions, 22 plan files, and 4 `docs/plans/` engineering plans — this file consolidates all of it.

---

## Table of contents

1. [How to use this file](#1-how-to-use-this-file)
2. [Project TL;DR](#2-project-tldr)
3. [Current snapshot](#3-current-snapshot)
4. [Active plans (the 4 from INDEX.md)](#4-active-plans-the-4-from-indexmd)
5. [Photo-extraction-engine epic walk-through](#5-photo-extraction-engine-epic-walk-through)
6. [Attribute classifier story (deep dive)](#6-attribute-classifier-story-deep-dive)
7. ["What next" decision menu](#7-what-next-decision-menu)
8. [Parallel tracks on the branch](#8-parallel-tracks-on-the-branch)
9. [File paths index](#9-file-paths-index)
10. [Commands cheat sheet](#10-commands-cheat-sheet)
11. [Environment & tooling pins](#11-environment--tooling-pins)
12. [Secrets inventory](#12-secrets-inventory)
13. [Git state surgery recommendations](#13-git-state-surgery-recommendations)
14. [Resumption prompt for a fresh Claude session](#14-resumption-prompt-for-a-fresh-claude-session)
15. [Risk & open questions log](#15-risk--open-questions-log)

---

## 1. How to use this file

In any future Claude Code session at `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do`, paste:

```
Read @docs/SESSION_HANDOFF_BRIEF.md for complete project context. My priority right now is [X].
```

Regenerate this file when any of these happen:
- A merge into `main` lands (so the "75 commits ahead" line becomes stale)
- Attempt-3 of the attribute classifier finishes (so the metrics tables in section 6 need updating)
- Phase 9 dogfood kicks off or completes
- Another top-level plan gets added to `docs/plans/INDEX.md`

Regeneration pattern: ask Claude to "update `docs/SESSION_HANDOFF_BRIEF.md` to reflect the current state" — the Explore-then-write loop takes ~5 minutes.

---

## 2. Project TL;DR

**What it is:** An iOS-native wardrobe decision engine that generates daily styled outfit suggestions from clothing the user has uploaded. A rebuild of the existing web-based "Digital Atelier" app (`trkngit/Wardrobe` — React/C#/.NET) onto SwiftUI + Supabase.

**Who it's for:** Someone who wants "what should I wear today" answered from a photo of their closet, grounded in real fashion theory rather than a random-shuffle outfit feed.

**The core value prop:** a 7-dimension style engine that scores outfit combinations on professional-grade criteria (proportion, color harmony, texture, formality, formula, versatility, occasion). Ship target is an app that "feels like a stylist friend, not a matching algorithm."

**Stack:**
- **Frontend:** SwiftUI (iOS 17+, `@Observable`)
- **Backend:** Supabase (PostgreSQL, Auth, Storage, Edge Functions)
- **Image analysis:** CoreImage + Vision + Core ML (on-device, no cloud inference)
- **Image loading:** Kingfisher
- **Local cache:** SwiftData
- **Deps:** Swift Package Manager

**Architecture:** MVVM + Repository + Service. View → ViewModel (`@Observable`) → Service → Repository → Supabase / SwiftData.

**7-dimension style engine (with weights):**
1. Proportion Balance (0.15)
2. Color Harmony (0.25)
3. Texture Mix (0.10)
4. Formality Coherence (0.15)
5. Outfit Formula (0.15)
6. Versatility (0.10)
7. Occasion Context (0.10)

**The photo-extraction-engine epic** (the active branch `feature/photo-extraction-engine`) is the "upload a photo → auto-detect garments → pre-fill the Add Item form → save to wardrobe" feature. It's composed of 4 engineering plans that interlock — see section 5.

---

## 3. Current snapshot

**Branch:** `feature/photo-extraction-engine`
**Head commit:** `d4ac188 feat(attr): ship attempt-2 winner — 6-bit palettized mlpackage (s1337, macro_f1=0.447)`
**Delta vs main:** **75 commits ahead, 0 behind** — no merge yet.
**Main head:** `f3f7b96 fix(engine): unblock outfit save + generation vocabulary + error UX`

**Most recent 5 commits on feature branch:**
```
d4ac188 feat(attr): ship attempt-2 winner — 6-bit palettized mlpackage (s1337, macro_f1=0.447)
5bafd88 feat(attr): 3-seed focal-loss run — winner seed-1337 macro_f1=0.4468078929733828
50997dc feat(ml): add focal loss + label smoothing + weight-clamp flags to trainer
d645cd8 docs(attr): log autonomous pod run + baseline ship decision matrix
5461e13 feat(attr): ship laptop-trained baseline + phase 4 export pipeline
```

**Just shipped (commit `d4ac188`, 2026-04-22):**
- `WardrobeReDo/ML/AttributeClassifier.mlpackage` — 6-bit palettized Core ML model, 1.3 MB, iOS 17+ target, `fit_probs` output shape `(1, 5)`
- Full gate-status tables, per-seed comparison, per-class F1 breakdown added to `docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md`

**iOS test status:** `** TEST SUCCEEDED **` on iPhone 17 Pro simulator with the new mlpackage.

**Feature flag state:**
- `FeatureFlags.isMultiGarmentEnabled`: **`true`** by default (ships)
- `FeatureFlags.isAttributeDetectionEnabled`: **`false`** by default (awaiting Phase 9 dogfood validation)

File that governs these: `WardrobeReDo/Config/FeatureFlags.swift`.

**Uncommitted working-tree state:**
- Modified: `WardrobeReDo.xcodeproj/project.pbxproj` — Xcode auto-regen artifact, safe to commit or ignore
- Untracked scratch dirs: `data/`, `logs/`, `checkpoints/attr-smoke/`, `checkpoints/attr-full/export/`, `.claude/worktrees/*`, Xcode user settings

---

## 4. Active plans (the 4 from INDEX.md)

Source of truth: [`docs/plans/INDEX.md`](plans/INDEX.md). All plans live under `docs/plans/` and are git-tracked (unlike `~/.claude/plans/*.md`, which are ephemeral and overwritten per plan-mode session).

| # | Plan | Status | One-liner |
|---|------|--------|-----------|
| 1 | [`2026-04-18-multi-garment-detection`](plans/2026-04-18-multi-garment-detection.md) | **IN PROGRESS** — 10-epoch pod training at epoch 7 val phase; iOS real-weights validated (461/461 tests); flag flipped to `true` pending final wrap-up | RF-DETR-Seg + Fashionpedia: detect multiple garments in one photo, multi-pick UI, sequential per-item save loop |
| 2 | [`2026-04-18-autonomous-5hr-window`](plans/2026-04-18-autonomous-5hr-window.md) | **SHIPPED P1+P2** (bbox AP@0.5=0.65 / segm=0.64); P3 unblocked | Autonomous Phase-1 finish + pre-authorized Phase-2 full train with guardrails, budget caps, and phone push dispatch |
| 3 | [`2026-04-19-multi-garment-crash-recovery`](plans/2026-04-19-multi-garment-crash-recovery.md) | **PROPOSED** (v1.1 punch-list) | Persist `pendingProposalQueue` to SwiftData so a mid-batch jetsam doesn't lose unsaved garments |
| 4 | [`2026-04-19-auto-attribute-detection`](plans/2026-04-19-auto-attribute-detection.md) | **IN PROGRESS** — Phases 0–4 DONE, Phase 6 wiring + Phase 7 migration landed; Phase 9 dogfood not yet run | Auto-detect category/texture/fit/seasons/occasions, pre-select on the Add Item form, user-editable, correction tracking via new `detected_attributes` JSONB column |

The two "in progress" plans both sit on the same branch; merging requires the last gate of each to clear.

---

## 5. Photo-extraction-engine epic walk-through

The 4 plans compose into one end-to-end feature. The flow from the user's perspective is:

```
📷 Camera / Library picker
   ↓
🔍 Multi-garment detection (RF-DETR-Seg)
   → segments N garments in one photo, returns bounding boxes + masks
   ↓
✂️  Crop each garment to a 224×224 attribute-friendly crop
   ↓
🏷  Attribute classifier (MobileNetV3-Small, Option C)
   → fit class ∈ {oversized, relaxed, regular, slim, cropped}
   ↓
📋 Rules engine (season/occasion inferred from category + fit)
   ↓
📝 Pre-fill Add Item form with detected attributes
   → user can edit any field before saving
   ↓
💾 Save to wardrobe (correction delta logged in `detected_attributes` JSONB)
```

**Mapping to the 4 plans:**

- **Plan 1 (multi-garment-detection)** owns the first two boxes — the RF-DETR-Seg model, the crop extraction, and the iOS multi-pick UI that lets the user confirm which detected garments to save.
- **Plan 4 (auto-attribute-detection)** owns boxes 3–5 — the fit classifier, the rules engine that maps category+fit to season/occasion, and the Add Item form wiring. This is where this session's work landed.
- **Plan 2 (autonomous-5hr-window)** is the training infrastructure that ran unattended overnight to produce the shipped RF-DETR-Seg checkpoint.
- **Plan 3 (crash-recovery)** is a v1.1 punch-list item — currently if the app is killed mid-batch with unsaved garments, the queue is lost. Fix is persisting `pendingProposalQueue` to SwiftData. Not blocking for v1 ship.

**What ships today, behind the flag:** every piece except Phase 9 dogfood validation. Multi-garment detection is already on (`isMultiGarmentEnabled` default = `true`); auto-attribute pre-fill is off (`isAttributeDetectionEnabled` default = `false`).

---

## 6. Attribute classifier story (deep dive)

This is where the most decisions live right now. The short version: **the classifier works, is shipped, but fails all 4 quality gates** — and the user has to decide whether that's acceptable for the dogfood milestone.

### 6.1 Scope lock — Option C fit-only

Per [`docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md`](plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md) and `BLOCKERS.md#D-2`:

- The classifier is **fit-only**, 5 classes: `oversized`, `relaxed`, `regular`, `slim`, `cropped`
- **Texture was deferred to v1.1** because Fashionpedia's texture labels have too much inter-annotator disagreement to train on reliably
- Single-head architecture: `MobileNetV3-Small` backbone → global avg pool → 5-way softmax
- The iOS decode path (`AttributeClassifierService.decode`) handles the "no texture head" case via nil-tolerant MLMultiArray lookup, so `predictedTexture` is always `nil` with confidence `0.0`

This locks the classifier down to a scope we can actually achieve; texture becomes a v1.1 problem once we have a better dataset or annotation pipeline.

### 6.2 Dataset — Fashionpedia fit crops

Source: [`notebooks/training/scripts/prepare_attribute_dataset.py`](../notebooks/training/scripts/prepare_attribute_dataset.py)

- Pulls Fashionpedia's `instances_attributes_{train,val}2020.json` + images from S3 (CVDF mirror)
- Filters to the 33 main apparel classes, then crops each instance segmentation to a 224×224 square
- Maps Fashionpedia attribute indices to the 5 fit classes via [`fashionpedia_attr_to_ios_enum.py`](../notebooks/training/scripts/fashionpedia_attr_to_ios_enum.py)
- Output manifest: `data/fashionpedia/attr_crops/manifest.csv` + `manifest_meta.json`

**Split sizes (verified from last pod run):**
- Train: **42,916** crops
- Val: **1,206** crops
- Per-class val support (this is the key constraint on oversized F1): `oversized=16`, `relaxed=170`, `regular=352`, `slim=205`, `cropped=463`

### 6.3 Attempt 1 — Laptop baseline (2026-04-19)

Trained on the laptop's Apple Silicon MPS, hit a checkpoint at epoch 3 and was used as the first ship (commit `5461e13`).

**Hyperparameters:**
- backbone: `MobileNetV3-Small` (ImageNet pretrained)
- `batch_size=64`, `lr=3e-4`, `epochs=4` (ran out of patience, epoch-3 ckpt was best)
- loss: class-weighted cross-entropy (weights derived from train split distribution)
- device: MPS

**Metrics (val, 1,206 samples):**

| Metric | Value | Gate | Status |
| --- | --- | --- | --- |
| top-1 | **0.454** | ≥ 0.75 | **FAIL** |
| macro-F1 | **0.352** | ≥ 0.55 | **FAIL** |
| oversized F1 | **0.045** | ≥ 0.30 | **FAIL** |
| calibration @ ≥0.80 realized acc | **0.570** | ≥ 0.90 | **FAIL** |

Shipped as the first mlpackage to validate the full pipeline (trainer → checkpoint → coremltools → palettization → iOS bundle). Worked end-to-end; iOS tests 475/475 green. Known to be bad at oversized (F1 of 0.045 on 16 samples = essentially no signal).

### 6.4 Attempt 2 — Pod 3-seed focal-loss run (2026-04-22, this session)

Ran on a RunPod `RTX A4500` community pod (`$0.19/hr`, 20 GB VRAM, 50 GB persistent volume at `/workspace`). Full recipe and driver script are in the original `wiggly-sparking-cascade.md` plan file and on the pod at `/workspace/wardrobe-redo-mobile/scripts/pod_attr_train.sh`.

**Hyperparameter changes from attempt 1:**
- 3 parallel seeds (42, 1337, 2024) trained concurrently on one GPU (each `bs=128`, `~2.1 GB VRAM` each, ~66% GPU utilization total)
- `epochs=40` per seed
- **focal loss, γ=2** (Lin 2017 — down-weights easy examples, forces the model to pay attention to the tail class)
- **label smoothing ε=0.05** (regularizes overconfidence)
- **class-weight cap 20** (prevent the oversized class's 42k/400 ratio from dominating the gradient)

**Per-seed results (val, 1,206 samples):**

| Seed | top-1 | macro-F1 | high-conf count @0.80 | high-conf realized acc |
| --- | --- | --- | --- | --- |
| 42 | 0.541 | 0.446 | 2 | 1.000 |
| **1337** ← shipped | **0.546** | **0.447** | **0** | n/a |
| 2024 | 0.522 | 0.440 | 7 | 0.571 |

Pick-best logic: highest macro_f1 wins. Winner = seed-1337. Promoted to `checkpoints/attr-full/`, pushed as `5bafd88`, exported locally to `WardrobeReDo/ML/AttributeClassifier.mlpackage`, shipped as `d4ac188`.

**Per-class F1 (winner seed-1337):**

| Class | Precision | Recall | F1 | Support |
| --- | --- | --- | --- | --- |
| oversized | 0.097 | 0.375 | **0.154** | 16 |
| relaxed | 0.422 | 0.365 | 0.391 | 170 |
| regular | 0.468 | 0.372 | 0.415 | 352 |
| slim | 0.545 | 0.590 | 0.567 | 205 |
| cropped | 0.685 | 0.732 | **0.708** | 463 |

**Gate status (attempt 2):**

| Metric | Value | Gate | Status | Δ vs baseline |
| --- | --- | --- | --- | --- |
| val top-1 | **0.546** | ≥ 0.75 | **FAIL** | +0.092 |
| val macro-F1 | **0.447** | ≥ 0.55 | **FAIL** | +0.095 |
| oversized F1 | **0.154** | ≥ 0.30 | **FAIL** | +0.109 |
| calibration @ ≥0.80 | **n/a (0 samples)** | ≥ 0.90 | **FAIL** | regression |

All four gates still fail, **but three of four axes improved meaningfully.** Macro-F1 is up 27%, oversized F1 is up 3.4×, top-1 is up 20%.

### 6.5 Calibration regression — the UX concern

This is the one axis that got **worse.** Seed-1337 produces **zero** predictions above the 0.80 confidence threshold. Seed-2024 produces 7 (at 57% realized accuracy). Seed-42 produces 2 (at 100%).

**Why this happened:**
- Focal loss with γ=2 sharpens the decision boundary by down-weighting easy examples. In doing so, it effectively softens the softmax output (because the gradient rewards moving away from the confident region, not into it).
- Label smoothing ε=0.05 redistributes target probability from the true class (95%) across all classes, which teaches the model to never be fully confident.
- Both techniques are well-suited to training a robust classifier, but both **degrade calibration** — the model's confidence values become less useful as a reliable threshold.

**Why this matters for UX:**
- `AttributeClassifierService.decode` uses `0.80` as the pre-fill threshold. Below that, the iOS Add Item form shows the field as empty rather than as a suggestion.
- With s1337 shipping, the auto-attribute pre-fill will essentially **never fire** in production. The user will have to manually enter every field.
- That's a regression from the laptop baseline (which did have some confident predictions, at 57% accuracy).
- Seed-2024 would have been a more useful ship on this axis — some confident predictions at tolerable accuracy is better than none — but the pick-best logic keyed on `macro_f1` alone.

### 6.6 Dataset bottleneck — 16 oversized val samples

Even with perfect training, `oversized` has `support=16` in the val set. That means:
- The per-class F1 for oversized has **high variance** from any training run — one misclassification moves F1 by ~4 percentage points
- Hitting the `0.30` gate requires ~75% precision **and** ~55% recall simultaneously on 16 samples — hard to achieve with training alone
- Fashionpedia's oversized annotations are sparse because oversized is rare in commercial apparel photography

**The real fix is more oversized data.** Options:
1. Mine oversized crops from Fashionpedia's unlabeled boxes using a heuristic (e.g., bbox area vs garment template)
2. Copy-paste augmentation on the 16 known positives (heavy transforms at training time)
3. External data sources (Vinted / eBay / Poshmark oversized listings — license-safe path needs research)

---

## 7. "What next" decision menu

Four candidate paths forward. Each has a different cost/value profile.

### A. Ship it and step away

- **Cost:** $0, 0 min
- **Risk:** Calibration regression means auto-attribute pre-fill essentially never fires in dogfood — the feature silently doesn't work
- **Makes sense when:** You want to close the session, have other priorities, and are OK with Phase 9 dogfood revealing whether the pre-fill-rarely-fires failure mode is acceptable UX

### B. Merge + dogfood Phase 9

- **Cost:** ~30 min (PR, merge, enable flag locally, use the app)
- **Risk:** Low — you're on your own device only, flag defaults remain `false` in production
- **Makes sense when:** You want real usage data to inform attempt-3 priorities. Speculating about "will dropping label smoothing fix calibration?" without field data is how you optimize the wrong metric
- **Prerequisite:** Decide whether you want to merge to `main` before dogfood, or dogfood off the feature branch with a local install

### C. Attempt-3 retrain (calibration fix)

- **Cost:** ~$0.20, ~45 min laptop-free, same pod recipe
- **Recipe:** `--focal-gamma 1` (down from 2), `--label-smoothing 0.0` (down from 0.05). Everything else identical to attempt 2.
- **Hypothesis:** calibration recovers (some predictions get to >80%), macro_f1 gives back 1–2 points. Net for UX: better.
- **Risk:** the tail class (oversized) regresses because focal γ=1 is weaker at rebalancing. The gain on calibration might come at the cost of the oversized F1 improvement we just got.
- **Makes sense when:** You believe field usage will hinge on pre-fill firing frequency and the cost is low enough to try

### D. Augment oversized class (dataset-side)

- **Cost:** Several hours of engineering, then another $0.20 retrain
- **Scope:** Option 1: heuristic mining from Fashionpedia unlabeled boxes. Option 2: copy-paste augmentation on the 16 positives. Option 3: external dataset integration.
- **Risk:** The augmentation pipeline takes real time to build and validate
- **Makes sense when:** You've decided that oversized F1 ≥ 0.30 is a must-have gate rather than nice-to-have. In practice, "detect oversized fit" is a specialty use case (think streetwear) that might not be worth the engineering cost for v1

### Recommendation

**B (dogfood) first, then decide C vs D based on what you observe.** You don't yet know whether the calibration regression hurts in practice or whether it's a theoretical concern. One day of using the app with the flag on tells you more than any amount of hyperparameter speculation. The cost of dogfooding is lower than the cost of picking wrong for attempt-3.

---

## 8. Parallel tracks on the branch

Not everything on `feature/photo-extraction-engine` is attribute-classifier work. The branch also contains:

### 8.1 Multi-garment detection (Plan 1, most of the branch weight)

- `0cced68 feat(mg): wrap up multi-garment detection — ship rank-5 mlpackage + flip flag on`
- RF-DETR-Seg model shipped at `WardrobeReDo/ML/RFDETRSegFashion.mlpackage`
- iOS tests: 461/461 green against real weights
- Feature flag `isMultiGarmentEnabled` defaults to `true`
- Still has the "final checkpoint wrap-up" pending per INDEX.md — worth a close re-read before merging if you want that polished

### 8.2 Multi-garment crash recovery (Plan 3)

- **Proposed but not started** — would land as a v1.1 follow-up
- Scope: persist `pendingProposalQueue` to SwiftData on app suspend, restore on foregrounding
- Currently if the app is jetsammed mid-batch with ≥1 unsaved garments, the user loses them
- Plan file: [`docs/plans/2026-04-19-multi-garment-crash-recovery.md`](plans/2026-04-19-multi-garment-crash-recovery.md)
- Not blocking for v1

### 8.3 Supabase migrations

Three migrations landed during the photo-extraction-engine work:

| Migration | What it does |
| --- | --- |
| `00007_*` | Masked image column for processed garment photos |
| `00008_*` | Source-photo grouping (so N garments from one photo link back to the originating upload) |
| `00009_*` | `detected_attributes` JSONB column on `wardrobe_items` — stores pre-fill suggestions alongside the user's final save, for correction-delta tracking |

All three are in `supabase/migrations/`. None are deployed to production yet (feature branch hasn't merged).

### 8.4 iOS scaffolding

Key new files:

- `WardrobeReDo/Services/ImageService.swift` — entry point for photo-to-garments pipeline
- `WardrobeReDo/Services/Extraction/ClothingExtractionService.swift` — single-garment extraction (legacy, pre-multi-garment)
- `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` — multi-garment batch orchestration
- `WardrobeReDo/Services/Extraction/MultiGarmentSmokeTest.swift` — on-device inference smoke test
- `WardrobeReDo/Services/Extraction/AttributeClassifierService.swift` — Phase 4 fit-classifier decode path
- `WardrobeReDo/Services/Extraction/SAM2Extractor.swift`, `WardrobeReDo/Services/Extraction/VisionForegroundExtractor.swift` — alternative extractors (experimental)

Plus `WardrobeReDo/Config/FeatureFlags.swift` for the two flag gates.

---

## 9. File paths index

### 9.1 Plans (all git-tracked under `docs/plans/`)

| Path | Purpose |
| --- | --- |
| [`docs/plans/INDEX.md`](plans/INDEX.md) | Master plan index with status column |
| [`docs/plans/2026-04-18-multi-garment-detection.md`](plans/2026-04-18-multi-garment-detection.md) | RF-DETR-Seg training + iOS multi-pick UI |
| [`docs/plans/2026-04-18-multi-garment-detection-research.md`](plans/2026-04-18-multi-garment-detection-research.md) | Long-form research notes for Plan 1 |
| [`docs/plans/2026-04-18-autonomous-5hr-window.md`](plans/2026-04-18-autonomous-5hr-window.md) | Overnight autonomous training runbook (shipped) |
| [`docs/plans/2026-04-19-multi-garment-crash-recovery.md`](plans/2026-04-19-multi-garment-crash-recovery.md) | Proposed v1.1 jetsam-survival patch |
| [`docs/plans/2026-04-19-auto-attribute-detection.md`](plans/2026-04-19-auto-attribute-detection.md) | Parent attribute-detection plan (Phases 0–9) |
| [`docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md`](plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md) | Option C scope lock (fit-only, defer texture) |
| [`docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md`](plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md) | Phases 2–4 training handoff + full run summaries |
| [`docs/plans/2026-04-19-auto-attribute-detection/BLOCKERS.md`](plans/2026-04-19-auto-attribute-detection/BLOCKERS.md) | Edge-case registry (D-2: texture deferral, D-3: nil-tolerant decode, D-6: structured fit, P2-* data prep) |
| [`docs/plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md`](plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md) | Season / occasion derivation rules (category + fit → season set) |
| [`docs/plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md`](plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md) | Phase 9 validation template (empty pending dogfood run) |

### 9.2 Training scripts (`notebooks/training/scripts/`)

All Python 3.11/3.12 compatible. Run via the `.venv/bin/python` from the repo root.

| Script | One-line purpose |
| --- | --- |
| `prepare_fashionpedia.py` | Download Fashionpedia raw + convert to Roboflow COCO layout |
| `prepare_attribute_dataset.py` | Extract 224×224 fit-attribute crops (Option C, 5-class) |
| `train_attributes.py` | MobileNetV3-Small single-head trainer (focal + LS + class weights) |
| `export_attribute_classifier.py` | Convert `attr_best.pth` to 6-bit palettized `AttributeClassifier.mlpackage` |
| `eval_attributes.py` | Per-class F1 + calibration curve + confusion matrix on val |
| `audit_fashionpedia_attributes.py` | Inventory Fashionpedia attributes for scope lock |
| `fashionpedia_attr_to_ios_enum.py` | Map Fashionpedia indices to iOS enum cases |
| `test_prepare_attribute_dataset.py` | Unit tests for preparer edge cases |
| `test_rank5_equivalence.py` | Verify palettization doesn't break decode |
| `test_coreml_local_random.py` | Smoke test mlpackage loads + runs on random input |
| `pod_health_check.sh` | SSH + GPU + Python + CUDA sanity on pod |
| `watch_pod.sh` | Streaming tail of remote training log |
| `wrap_up_local.sh` | Post-pod laptop automation: eval + export + iOS build + push |
| `probe_env.py` | Pre-pod environment validation |

### 9.3 iOS services

| Path | Role |
| --- | --- |
| `WardrobeReDo/App/` | `@main` entry, `AppState`, `ContentView` |
| `WardrobeReDo/Config/FeatureFlags.swift` | `isMultiGarmentEnabled`, `isAttributeDetectionEnabled` |
| `WardrobeReDo/Config/Secrets.plist` | Supabase URL + anon key (gitignored) |
| `WardrobeReDo/Services/ImageService.swift` | Pipeline entry point |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | Multi-garment orchestration |
| `WardrobeReDo/Services/Extraction/AttributeClassifierService.swift` | Fit-classifier decode (Option C) |
| `WardrobeReDo/Services/Extraction/MultiGarmentSmokeTest.swift` | On-device smoke test |
| `WardrobeReDo/Services/StyleEngine/` | 7-dimension outfit scorer + generator |
| `WardrobeReDo/Repositories/` | Supabase data access |

### 9.4 Checkpoints & ML artifacts

| Path | What's there |
| --- | --- |
| `checkpoints/attr-full/` | **Winner** (seed-1337) promoted: `attr_best.pth` (Git-LFS), `run_summary.json`, `eval/{summary,per_class,calibration,confusion_matrix}.{json,png}`, `export/` |
| `checkpoints/attr-full-s1337/` | Winner's full training artifacts + 40-epoch metrics |
| `checkpoints/attr-full-s42/` | Seed-42 full artifacts (F1=0.446) |
| `checkpoints/attr-full-s2024/` | Seed-2024 full artifacts (F1=0.440, 7 high-conf preds) |
| `checkpoints/attr-smoke/` | Laptop baseline (epoch 3, macro_f1=0.352) — untracked |
| `WardrobeReDo/ML/AttributeClassifier.mlpackage` | **Ship artifact** — 6-bit palettized, 1.3 MB, `fit_probs` only |
| `WardrobeReDo/Models/CoreML/RFDETRSegFashion.mlpackage` | Multi-garment detector, rank-5 palettized |
| `WardrobeReDo/Models/CoreML/SAM2Tiny.mlmodelc` | SAM2 tiny backbone (alternative extractor path) |

### 9.5 Memory & ephemeral plans

| Path | Purpose |
| --- | --- |
| `~/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/memory/MEMORY.md` | Auto-loaded memory index; points at `project_wardrobe_redo.md` + this repo's INDEX.md |
| `~/.claude/plans/wiggly-sparking-cascade.md` | **This session's** plan trace (ephemeral; gets overwritten by the next plan-mode session). Do **not** treat as durable — this brief is the durable artifact. |

---

## 10. Commands cheat sheet

All paths relative to `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/`.

### iOS build & test

```bash
# Regenerate Xcode project from project.yml
xcodegen generate

# Run the full iOS test suite on iPhone 17 Pro sim
xcodebuild test \
  -scheme WardrobeReDo \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Quick build-only (no tests)
xcodebuild -scheme WardrobeReDo -sdk iphonesimulator build
```

### Export classifier locally (after a pod run)

```bash
# Activate venv and run the Core ML exporter
.venv/bin/python notebooks/training/scripts/export_attribute_classifier.py \
  --checkpoint checkpoints/attr-full/attr_best.pth \
  --out checkpoints/attr-full/export \
  --copy-to-app
```

This produces `checkpoints/attr-full/export/AttributeClassifier_fp32.mlpackage` (intermediate) and `AttributeClassifier.mlpackage` (6-bit palettized ship artifact), then copies the palettized version into `WardrobeReDo/ML/`.

### Evaluate a checkpoint

```bash
.venv/bin/python notebooks/training/scripts/eval_attributes.py \
  --checkpoint checkpoints/attr-full/attr_best.pth \
  --dataset-root data/fashionpedia/attr_crops \
  --report-dir checkpoints/attr-full/eval \
  --split val
```

Produces `summary.json` + `per_class.json` + `calibration.png` + `confusion_matrix.png`.

### Git inspection

```bash
# See what's on the branch but not on main
git log --oneline main..feature/photo-extraction-engine

# File-level diff summary vs main
git diff main...feature/photo-extraction-engine --stat

# Current commit count ahead
git rev-list --count main..feature/photo-extraction-engine
```

### RunPod (if running attempt-3)

Recipe lives in `scripts/autonomous_attr_train.sh` and in the detailed phase-by-phase plan in `docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md`. Summary:

```bash
# Verify RunPod auth
runpodctl me

# GPU fallback chain (first available wins)
runpodctl pod create \
  --name wardrobe-attr-train-v3 \
  --gpu-id "NVIDIA RTX A4500" \
  --gpu-count 1 \
  --cloud-type COMMUNITY \
  --container-disk-in-gb 60 \
  --volume-in-gb 50 \
  --volume-mount-path /workspace \
  --ports '22/tcp' \
  --env '{"RUNPOD_API_KEY":"$RUNPOD_API_KEY"}' \
  --ssh -o json

# Monitor a running pod
ssh -i ~/.ssh/id_ed25519_runpod -p <PORT> root@<IP> \
  "tail -f /workspace/pod-train.log"

# Stop a pod (halts compute billing, keeps volume)
runpodctl stop pod <POD_ID>

# Permanently remove pod + volume (destructive — user runs)
runpodctl remove pod <POD_ID>
```

Deploy key handling: generate on pod (`ssh-keygen` in `/workspace/ssh-repo/`), register via `gh repo deploy-key add --allow-write --repo trkngit/wardrobe-redo-mobile`, revoke with `gh repo deploy-key delete <id> --repo ...` after the run.

---

## 11. Environment & tooling pins

**Python (`.venv/` at repo root, Python 3.12):**

| Package | Version | Why this pin |
| --- | --- | --- |
| `torch` | `2.5.1` | coremltools 8.1 officially pins `2.4.0` but `2.5.1` works with a `"Torch version 2.5.1 has not been tested"` warning |
| `torchvision` | `0.20.1` | Paired with torch 2.5.1 |
| `coremltools` | `8.1` | iOS 17 ML Program format + 6-bit palettize support |
| `scikit-learn` | latest | Required for k-means palettization (coremltools requires it for LUT gen) |
| `pillow` | latest | Image I/O in the prep + training pipelines |
| `numpy` | installed system | (torch bundles compatible version) |

**Training scripts:** author assumes `python==3.11` per `notebooks/training/requirements.txt`. Current local `.venv` is on `3.12`. Works for export; pod uses Python 3.11.

**iOS:**
- Xcode with iOS 17 SDK
- `xcodegen` 2.45.3 (via Homebrew)
- `xcrun simctl` for simulator management
- iPhone 17 Pro sim (already booted at `/Users/tarkansurav/Library/Developer/CoreSimulator/...`)

**Git:**
- `git-lfs` tracks `**/*.mlpackage/**` and `*.pth` (see `.gitattributes`)
- `gh` CLI authenticated as `trknsrv@gmail.com` with `repo` scope

**RunPod:**
- CLI version on laptop: `runpodctl` v2 — syntax is `runpodctl pod stop <id>`, `runpodctl pod list`, etc.
- CLI version baked into the older pod images: `runpodctl` v1.14.15-dac76ad — syntax is `runpodctl stop pod <id>`. Watch for this mismatch if driver scripts fail.
- SSH key: `~/.ssh/id_ed25519_runpod` (already registered on RunPod account)

---

## 12. Secrets inventory

**In-repo, gitignored:**
- `WardrobeReDo/Config/Secrets.plist` — Supabase URL + anon key. Verified in `.gitignore`.

**Outside the repo:**
- `~/.runpod/config.toml` — RunPod API key `rpa_8G...dh7t`. Never written to the repo. Passed to the pod once via `--env` at creation, available on the pod as `$RUNPOD_API_KEY`.

**GitHub:**
- `gh auth status` → authenticated as `trknsrv@gmail.com`, `repo` scope
- No OAuth tokens in repo or shell history

**Deploy keys on `trkngit/wardrobe-redo-mobile`:**
- All pod-generated deploy keys have been revoked: `148116555`, `148126318`, `149202578` (and anything else from prior sessions). If spinning up another pod, generate a fresh deploy key, register via `gh repo deploy-key add`, and revoke when done.

**Safety rules:**
- Never commit `Secrets.plist`
- Never commit `.runpod/config.toml`
- Never commit a pod's SSH private key (`/workspace/ssh-repo/id_ed25519_repo`)

---

## 13. Git state surgery recommendations

### Uncommitted modified

- `WardrobeReDo.xcodeproj/project.pbxproj` — this gets regenerated by `xcodegen` every time `project.yml` changes. The diff here is usually non-semantic (Xcode UUIDs, file orderings). Safe to either commit or revert; not critical for ship.

### Untracked directories

**Candidates for `.gitignore`:**

```gitignore
# Training scratch
data/
logs/
checkpoints/attr-smoke/
checkpoints/attr-full/export/
.claude/worktrees/

# Xcode user state
WardrobeReDo.xcodeproj/project.xcworkspace/xcshareddata/
WardrobeReDo.xcodeproj/project.xcworkspace/xcuserdata/
```

(Check current `.gitignore` first — some of these may already be there.)

**Candidate for committing, if still useful:**

- `scripts/autonomous_attr_train.sh` — the bash harness that orchestrates parallel pod runs. If you intend to do attempt-3 with the same recipe, commit it. If you'll regenerate it from the plan each time, delete it.

### Branch strategy before merge

- 75 commits ahead is a lot — consider squashing into a few logical commits if policy allows (one per phase: multi-garment, attribute-taxonomy, attribute-trainer, attribute-export, attribute-wiring, attribute-migration)
- Or open the PR as-is and merge it as one large squash — the individual commits are well-labeled (`feat(attr): phase N — ...`) and are useful history
- **Do not push to main directly** — Phase 9 dogfood should gate the merge per the parent plan

---

## 14. Resumption prompt for a fresh Claude session

Copy-paste into a new Claude Code session at the repo root:

```
I'm resuming work on the Wardrobe Re-Do project. Read
@docs/SESSION_HANDOFF_BRIEF.md for the complete context.

My current priority is: [FILL IN — e.g. "run Phase 9 dogfood",
"attempt-3 retrain with γ=1 no label smoothing", "merge to main",
"start on multi-garment crash recovery"].

Before you take any action, summarize what you understand about the
project state and confirm the priority with me. Do not start
implementing until I give the go-ahead.
```

If you don't have a priority yet, use:

```
I'm resuming work on the Wardrobe Re-Do project. Read
@docs/SESSION_HANDOFF_BRIEF.md for the complete context. Help me
decide what to do next from the decision menu in section 7.
```

---

## 15. Risk & open questions log

### Known open issues

| # | Issue | Where it's tracked | Severity |
| --- | --- | --- | --- |
| 1 | Calibration regression — winner s1337 has zero >0.80 confidence predictions | This brief § 6.5, `ATTRIBUTE_TRAINING_PLAN.md` § "Autonomous pod run — 2026-04-21" | High for UX, but gated by `isAttributeDetectionEnabled=false` |
| 2 | Feature flag `isAttributeDetectionEnabled` is `false` — auto-attribute pre-fill doesn't fire in production | `WardrobeReDo/Config/FeatureFlags.swift:56-65`, parent plan Phase 9 | Intentional until dogfood validation |
| 3 | Main branch not touched, 75 commits of work unmerged | Git | High — the longer this delays, the harder the merge |
| 4 | Multi-garment detection pod checkpoint is at epoch 7; final wrap-up pending | `docs/plans/2026-04-18-multi-garment-detection.md` status line in INDEX.md | Medium — need to wrap before merge |
| 5 | 16 oversized val samples is a hard dataset ceiling | This brief § 6.6 | Medium — attempt-3 alone won't clear the 0.30 gate |
| 6 | `scripts/autonomous_attr_train.sh` is untracked | Git status | Low — commit or delete decision |
| 7 | Phase 9 dogfood not yet run; `DOGFOOD_RESULTS.md` is empty | `docs/plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md` | Gates the attribute-detection flag flip |
| 8 | `project.pbxproj` has uncommitted xcodegen regeneration | Git status | Low — cosmetic diff |
| 9 | 4 existing Claude Code sessions still open — all pre-this-brief, context-heavy | User action | User should close or consolidate them after loading this brief in a fresh session |

### Open questions for the user

- Do you want attempt-3 before or after dogfood?
- Is the calibration regression acceptable if dogfood confirms pre-fill rarely fires?
- Do you plan to merge to main before Phase 9, or keep everything on the feature branch until the flag is safely flipped?
- Should `scripts/autonomous_attr_train.sh` be committed as a durable training artifact, or is it scratch?
- Is oversized F1 ≥ 0.30 a hard gate for v1, or a nice-to-have? (Determines whether option D — augment oversized class — is worth the engineering cost.)

---

## Appendix: change history of this file

- **2026-04-22** — Initial version. Generated after pod attempt-2 shipped (commit `d4ac188`). Covers the end of the `feature/photo-extraction-engine` training arc and sets up the Phase 9 / attempt-3 decision point.
