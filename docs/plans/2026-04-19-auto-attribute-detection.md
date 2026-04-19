# Plan — Auto-Attribute Detection (Category, Texture, Fit, Seasons, Occasions)

> **Scope:** Extend the camera → extraction flow so that when the user lands on the Add Item "details" step, the pickers for **category, texture, fit, seasons, and occasions** are already pre-selected based on the model's best guess. User can still override any field.
>
> **Slug:** `2026-04-19-auto-attribute-detection`
> **Status:** PROPOSED
> **Estimated effort:** ~2–3 weeks wall-clock (multiple parallel tracks)
> **Parent plan:** sibling to [2026-04-18-multi-garment-detection](./2026-04-18-multi-garment-detection.md)

---

## Table of contents

- [Context](#context)
- [Decisions locked in from Q&A](#decisions-locked-in-from-qa)
- [Architecture at a glance](#architecture-at-a-glance)
- [Parallel tracks overview](#parallel-tracks-overview)
- [Progress tracking convention (resumable across sessions)](#progress-tracking-convention-resumable-across-sessions)
- [Phases](#phases)
  - [Phase 0 — iOS foundation (no ML dependency)](#phase-0--ios-foundation-no-ml-dependency)
  - [Phase 1 — Fashionpedia attribute audit + taxonomy mapping](#phase-1--fashionpedia-attribute-audit--taxonomy-mapping)
  - [Phase 2 — Architecture decision + dataset prep v2](#phase-2--architecture-decision--dataset-prep-v2)
  - [Phase 3 — Attribute classifier training](#phase-3--attribute-classifier-training)
  - [Phase 4 — Core ML export + iOS inference wiring](#phase-4--core-ml-export--ios-inference-wiring)
  - [Phase 5 — Rules engine for seasons + occasions](#phase-5--rules-engine-for-seasons--occasions)
  - [Phase 6 — End-to-end pre-fill integration](#phase-6--end-to-end-pre-fill-integration)
  - [Phase 7 — Supabase schema + correction tracking](#phase-7--supabase-schema--correction-tracking)
  - [Phase 8 — UX polish ("AI detected" indicator)](#phase-8--ux-polish-ai-detected-indicator)
  - [Phase 9 — Validation + rollout](#phase-9--validation--rollout)
- [Open questions (deferred)](#open-questions-deferred)
- [End-to-end verification](#end-to-end-verification)
- [Critical files table (quick reference)](#critical-files-table-quick-reference)

---

## Context

**User request (verbatim, 2026-04-19):**
> "I also want our camera to be able to decide what the type of clothing the item is according to the criteria in our app. its category: whether it is a bottom top shoe Dress... its texture: cotton silk denim leather... fit Oversized Relaxed Regular... seasons: spring summer fall winter occasions: casual work date formal... I want the correct options pre selected after the screen that comes after the camera sequence. And still be changeable by the user in case it detected incorrect."

**What we already have (from exploration):**
- `ClothingCategory` (6 cases), `TextureType` (15), `FitAttribute` (6), `Season` (4), `Occasion` (6) — **all enums exist and are already persisted** (SwiftData + Supabase).
- `MaskProposal.predictedCategory` is **already computed** from the Fashionpedia class but **thrown away** in `AddItemViewModel.startNextProposal()` at [WardrobeReDo/ViewModels/AddItemViewModel.swift:676](WardrobeReDo/ViewModels/AddItemViewModel.swift:676), which hard-resets to `.top`.
- Fashionpedia raw data files (`instances_attributes_train2020.json`) **contain 294 fine-grained attribute annotations** (material, silhouette, neckline, etc.) — our `prepare_fashionpedia.py` **drops them** today. The attribute labels we need are already in the dataset we already pay for.
- No dataset exists for **seasons** or **occasions** — these must be derived.

**What's missing:** 4 independent pieces (dataset prep + training + iOS wiring + rules) plus a pre-fill glue layer.

---

## Decisions locked in from Q&A

| # | Question | Decision | Implication |
| - | -------- | -------- | ----------- |
| 1 | Ship order | **Hold for one big release** (no intermediate category-only ship) | Plan sequences everything; category pre-fill lands bundled with the rest |
| 2 | Season/occasion method | **Rules-based** (category × texture × subcategory → Season set + Occasion set) | No second training run needed; rules guarantee non-empty output (edge-case-safe by design) |
| 3 | Low-confidence behavior | **Only pre-select when ≥0.80 confidence** (else leave blank) | Need a shared `PrefillThreshold` constant + field-level confidence routing |
| 4 | Correction logging | **Yes, add `detected_attributes` JSONB to Supabase** | New migration `00009`, repository changes, survives a user's first-save flow |

---

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Capture pipeline                                                        │
│                                                                         │
│  Camera → ImageService.processImage()                                   │
│           │                                                             │
│           ├─► ClothingExtractionService  (single-garment fallback)      │
│           └─► MultiGarmentProposalService (RF-DETR-Seg)                 │
│                 │                                                       │
│                 │  per-proposal:                                        │
│                 ├─► category from pred_logits argmax  (EXISTS)          │
│                 ├─► texture + fit via AttributeClassifierService   NEW  │
│                 │      (separate MobileNetV3 mlpackage on cropped box)  │
│                 │      returns (texture?, textureConf, fit?, fitConf)   │
│                 └─► seasons + occasions via AttributeRulesEngine   NEW  │
│                        (category × texture × subcategory → sets)        │
│                                                                         │
│  MaskProposal { predictedCategory, predictedTexture, predictedFit,      │
│                 predictedSeasons, predictedOccasions, confidences }     │
│                                                                         │
│  AddItemViewModel.startNextProposal()                                   │
│    → apply ≥0.80 threshold per field                                    │
│    → pre-fill category / subcategory / texture / fitAttribute /         │
│       selectedSeasons / selectedOccasions                               │
│    → record in detectedAttributes map (for correction logging)          │
│                                                                         │
│  Details step form → user overrides → save                              │
│    → diff detectedAttributes vs final values                            │
│    → persist detected_attributes JSONB to Supabase                      │
└─────────────────────────────────────────────────────────────────────────┘
```

**Why separate attribute classifier (not a new head on RF-DETR-Seg):**
- RF-DETR training is a 10-hour pod run; modifying the head is high-risk. Separate MobileNetV3-Small on a cropped garment box is 3–4 hours on the same pod, independent artifact, independent iteration.
- Smaller mlpackage (~2 MB) vs re-exporting a 30 MB DETR package.
- If the attribute model regresses we roll it back without touching detection.
- Phase 2 re-evaluates this decision with a concrete cost estimate; reserving the right to merge heads later if evidence warrants.

---

## Parallel tracks overview

Five tracks that can run simultaneously once Phase 1 finishes. "Track ownership" means the track's primary deliverable, not an exclusive lock.

| Track | Covers | Depends on | Can run in parallel with |
| ----- | ------ | ---------- | ----------------------- |
| **A — iOS foundation** | Phase 0 | — | B, C, D, E |
| **B — Data & taxonomy** | Phase 1, 2 | Nothing for audit; Phase 2 prep depends on Phase 1 mapping | A, E (rules engine starts once mapping drafted) |
| **C — Training** | Phase 3 | Phase 2 (prepared dataset) | A, E |
| **D — Export + inference** | Phase 4 | Phase 3 first checkpoint (can start with dummy-weights mlpackage) | A, E |
| **E — Rules engine** | Phase 5 | Phase 1 taxonomy | A, B, C, D |
| **F — Integration + polish** | Phase 6, 7, 8, 9 | A, D, E | — (sequences tracks A/D/E into the product) |

Concretely: once Phase 1 (taxonomy) lands, **tracks C and E start the same day** while A has already been running. Track D ships its scaffolding (service + tests) against a dummy mlpackage **before** Phase 3 completes, so integration doesn't block on training.

---

## Progress tracking convention (resumable across sessions)

> **This is the most important section for context-loss survival.** Future Claude sessions (including mine after compaction) pick up from here.

1. **This plan file is the source of truth.** Never delete it. Mirror it to `docs/plans/2026-04-19-auto-attribute-detection.md` once approved (same convention as sibling plan `2026-04-18-multi-garment-detection.md`).
2. **Per-phase status** is tracked inline in each Phase section below. Update the `**Status:**` line as work progresses:
   - `PROPOSED` → not started
   - `IN PROGRESS (<handle>)` → someone is actively on it
   - `BLOCKED (<reason>)` → can't advance, with link to the blocker
   - `DONE` → merged + validated
3. **Artifacts directory:** create `docs/plans/2026-04-19-auto-attribute-detection/` for long-form outputs (taxonomy CSV, eval reports, rule tables). Link from each phase.
4. **INDEX.md entry:** add one row to [docs/plans/INDEX.md](docs/plans/INDEX.md) once this is promoted out of `~/.claude/plans/` and into the repo.
5. **Commits carry the slug.** Every commit message prefixed with `feat(attr):` or `chore(attr):` or `docs(attr):` makes git log grep trivial: `git log --grep 'attr)' --oneline`.
6. **"Next action" line at the bottom of each Phase** tells the next Claude session exactly what command to run / file to open to resume. No hunting.

---

## Phases

### Phase 0 — iOS foundation (no ML dependency)

**Status:** DONE (2026-04-19) — shipped behind default "no prediction" sentinels; real predictions populate these fields starting Phase 6. Full suite 475/475 green (+14 new prefill tests).
**Track:** A
**Depends on:** nothing (can start immediately)
**Est. effort:** 1 day

**Landed changes:**
- [WardrobeReDo/Models/MaskProposal.swift](../../WardrobeReDo/Models/MaskProposal.swift): +8 predicted-attribute fields with defaults so all 4 existing call sites compile unchanged
- [WardrobeReDo/Models/Enums/ClothingSubcategory.swift](../../WardrobeReDo/Models/Enums/ClothingSubcategory.swift): `fromFashionpediaClass(_:)` conservative mapper (nil for ambiguous classes like `pants` / `jacket` / `dress`)
- [WardrobeReDo/Config/AttributePrefill.swift](../../WardrobeReDo/Config/AttributePrefill.swift) (NEW): `minConfidence = 0.80` + `shouldPrefill(_:)` helper
- [WardrobeReDo/ViewModels/AddItemViewModel.swift](../../WardrobeReDo/ViewModels/AddItemViewModel.swift): `applyPrefill(from:)` + `defaultSubcategory(for:)` helpers; `detectedAttributes: [String: String]` snapshot dict; wired into `startNextProposal`; cleared on `reset` / `resetKeepingSource`
- [WardrobeReDoTests/Helpers/Mocks.swift](../../WardrobeReDoTests/Helpers/Mocks.swift): `MaskProposalFixture.make(...)` extended with all new predicted-attribute params defaulting to "no prediction"
- [WardrobeReDoTests/ViewModels/AddItemViewModelPrefillTests.swift](../../WardrobeReDoTests/ViewModels/AddItemViewModelPrefillTests.swift) (NEW): 14 tests covering category/subcategory/texture/fit threshold gating, seasons/occasions fallback, snapshot round-trip, reset-clears-snapshot

**Goal.** Extend the iOS data path so that predicted attributes can flow from `MaskProposal` into the Add Item form. Ship mock predictions end-to-end; zero model work.

**Why first.** Unblocks the entire iOS integration track. Without this, Phase 6 has nowhere to plug in.

**Changes:**

1. **Extend [WardrobeReDo/Models/MaskProposal.swift](WardrobeReDo/Models/MaskProposal.swift):**
   ```swift
   let predictedCategory: ClothingCategory?       // EXISTS
   let predictedCategoryConfidence: Float         // NEW — 0..1
   let predictedSubcategory: ClothingSubcategory? // NEW (derive from Fashionpedia label)
   let predictedTexture: TextureType?             // NEW — nil until attribute model ships
   let predictedTextureConfidence: Float          // NEW
   let predictedFit: FitAttribute?                // NEW
   let predictedFitConfidence: Float              // NEW
   let predictedSeasons: [Season]                 // NEW — populated by rules engine
   let predictedOccasions: [Occasion]             // NEW — populated by rules engine
   ```
   All new fields optional/defaulted so existing construction sites keep compiling.

2. **Subcategory mapping.** Extend `ClothingCategory.fromFashionpediaClass()` to ALSO return a subcategory hint. Today the Fashionpedia raw class is a string like `"shirt_blouse"` → we already collapse to `.top`; we can also return `.shirt` for subcategory in the same pass.
   - New: `ClothingSubcategory.fromFashionpediaClass(_ raw: String) -> ClothingSubcategory?`
   - File: [WardrobeReDo/Models/Enums/ClothingCategory.swift:49-110](WardrobeReDo/Models/Enums/ClothingCategory.swift:49)

3. **Pre-fill threshold constant.** New `WardrobeReDo/Config/AttributePrefill.swift`:
   ```swift
   enum AttributePrefill {
       static let minConfidence: Float = 0.80
       static func shouldPrefill(_ confidence: Float) -> Bool { confidence >= minConfidence }
   }
   ```

4. **Extend `AddItemViewModel.startNextProposal()`** at [WardrobeReDo/ViewModels/AddItemViewModel.swift:676](WardrobeReDo/ViewModels/AddItemViewModel.swift:676): replace the unconditional reset with:
   ```swift
   // Pre-fill from proposal when confidence passes threshold; fall back to
   // existing defaults when uncertain or when the attribute model hasn't shipped.
   category = (next.predictedCategory.flatMap {
       AttributePrefill.shouldPrefill(next.predictedCategoryConfidence) ? $0 : nil
   }) ?? .top
   subcategory = next.predictedSubcategory ?? defaultSubcategory(for: category)
   texture = AttributePrefill.shouldPrefill(next.predictedTextureConfidence) ? next.predictedTexture : nil
   fitAttribute = AttributePrefill.shouldPrefill(next.predictedFitConfidence) ? next.predictedFit : nil
   selectedSeasons = next.predictedSeasons.isEmpty ? Set(Season.allCases) : Set(next.predictedSeasons)
   selectedOccasions = next.predictedOccasions.isEmpty ? [.casual] : Set(next.predictedOccasions)
   ```
   Invariant: even with zero predictions, behavior is identical to today.

5. **Snapshot the pre-filled values** into a new `detectedAttributes: [String: String]` dict on the VM, keyed by field name (`"category"`, `"texture"`, …), value = enum raw. Set right after pre-fill. Needed by Phase 7 for correction diffing.

6. **Tests** — `WardrobeReDoTests/ViewModels/AddItemViewModelPrefillTests.swift`:
   - `prefillsCategoryWhenConfidenceAboveThreshold`
   - `skipsCategoryPrefillWhenBelowThreshold`
   - `fallsBackToAllSeasonsWhenRulesReturnEmpty`
   - `recordsDetectedAttributesSnapshot`

**Verification:**
```bash
xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WardrobeReDoTests/AddItemViewModelPrefillTests
```

**Next action:** Phase 0 DONE — next unblocked work is **Phase 1** (attribute audit script + taxonomy mapping) and **Phase 5** (rules engine), both of which can run in parallel now that the iOS foundation is in place.

---

### Phase 1 — Fashionpedia attribute audit + taxonomy mapping

**Status:** DONE (2026-04-19) — taxonomy + rules engine shipped in `e67d14b`; full-train audit CSV in `9430ad2` (295 attribute types, 333,401 annotations, 61.9% texture coverage). Replaced the earlier val-only placeholder (`1b34071`). **Reviewer sign-off 2026-04-19 locked Option C (defer TextureType to v1.1; ship fit-only).** See [ATTRIBUTE_TAXONOMY.md § Section 0](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md) and [BLOCKERS.md](./2026-04-19-auto-attribute-detection/BLOCKERS.md).
**Track:** B
**Depends on:** nothing
**Est. effort:** 1.5 days (plus ~1 hour of user review for the mapping)

**Goal.** Know exactly which Fashionpedia attributes correspond to our `TextureType` / `FitAttribute` enums, and produce a reviewable mapping spec.

**Changes:**

1. **Attribute audit script** `notebooks/training/scripts/audit_fashionpedia_attributes.py`:
   - Loads `instances_attributes_train2020.json`.
   - Dumps: distinct attribute IDs, attribute names, per-category frequency, coverage (% instances with ≥1 attribute).
   - Output: `docs/plans/2026-04-19-auto-attribute-detection/fashionpedia_attribute_inventory.csv`.

2. **Taxonomy mapping** `docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md`:
   - Section 1: Fashionpedia texture/material attributes → `TextureType` cases.
   - Section 2: Fashionpedia silhouette/fit attributes → `FitAttribute` cases.
   - Section 3: Fashionpedia categories → `ClothingSubcategory` cases (where not already covered).
   - Section 4: Gaps — which iOS enum cases have no Fashionpedia analogue (e.g., "tweed" might not be a first-class attribute; may collapse from multiple features).
   - Each row: `fashionpedia_attr_id | fashionpedia_name | ios_enum_case | confidence_note | example_image_count`.

3. **User review loop:** produce the mapping as a draft, get user to review/amend, commit.

**Output artifacts:**
- `fashionpedia_attribute_inventory.csv` (machine-readable)
- `ATTRIBUTE_TAXONOMY.md` (human-curated decisions)
- Lookup Python dict `fashionpedia_attr_to_ios_enum.py` used by dataset prep

**Verification:**
- Spot-check: pick 5 random images from `ATTRIBUTE_TAXONOMY.md` examples, visually confirm the mapping makes sense.
- Coverage floor: ≥80% of filtered training images must have at least one `TextureType`-mappable attribute. Log coverage in the audit CSV.

**Next action:** Download `instances_attributes_train2020.json` locally (pod already has it) and run the inventory script; pipe output to the CSV.

---

### Phase 2 — Architecture decision + dataset prep v2

**Status:** IN PROGRESS — preparer + lookup + smoke tests + training plan shipped 2026-04-19 (commit e0b4e8b); pod run of full-dataset preparer still pending (12 GB Fashionpedia download required). See [ATTRIBUTE_TRAINING_PLAN.md](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md) + [BLOCKERS.md § P2-1…P2-7](./2026-04-19-auto-attribute-detection/BLOCKERS.md).
**Track:** B
**Depends on:** Phase 1
**Est. effort:** 2 days

**Goal.** Produce a training-ready dataset of cropped garments labeled with **fit** (Option C scope — texture deferred to v1.1), and lock in the classifier architecture.

**Architecture lock-in (Option C):**
- **Separate MobileNetV3-Small single-head classifier** on cropped bounding-box regions.
- Alternative (rejected unless Phase 3 fails): add an attribute head to RF-DETR-Seg and retrain.
- Input: 224×224 crop from the source photo using the bounding box `MultiGarmentProposalService` already produces.
- Output: one softmax head → `fit_logits[5]` (oversized / relaxed / regular / slim / cropped).
- Texture head intentionally omitted — Fashionpedia v2 carries no main-fabric-type attributes ([ATTRIBUTE_TAXONOMY.md § Section 0](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md)). iOS decode path is already nil-tolerant so the absence is safe ([BLOCKERS.md#D-3](./2026-04-19-auto-attribute-detection/BLOCKERS.md)).
- Size budget: ≤5 MB mlpackage after 6-bit palettization (consistent with existing export pipeline's compression tricks).

**Changes:**

1. **`notebooks/training/scripts/fashionpedia_attr_to_ios_enum.py`** (SHIPPED, commit e0b4e8b):
   - Python source of truth for attr-id → `FitAttribute.rawValue` mapping.
   - Encodes P2-1 cropped gating (attr 146 only for top-like categories) and P2-2 multi-label tie-break (dual-snugness → drop; cropped beats snugness).
   - `TRAINABLE_FIT_LABELS` ordering is the contract Core ML export + iOS decode both depend on.

2. **`notebooks/training/scripts/prepare_attribute_dataset.py`** (SHIPPED, commit e0b4e8b):
   - Two-pass preparer: label resolution (pure CPU) → image crop (one-pass zip sweep).
   - BBox filters: area ≥ 2% of image, aspect in `[0.25, 4.0]` (P2-5).
   - Neutral-gray square padding before 224×224 resize.
   - Portable relative `image_path` in manifest (P2-7).
   - Emits `manifest.csv` (nine columns — see training plan § 3) + `manifest_meta.json` (class counts + filter constants for Phase 3 class-weight derivation, P2-3).
   - Idempotent: re-runs skip already-written crop files.

3. **`notebooks/training/scripts/test_prepare_attribute_dataset.py`** (SHIPPED, commit e0b4e8b):
   - Pytest-free smoke harness. 11 test groups covering every P2-x contract plus a synthetic end-to-end `process_split` on a tempdir. All green 2026-04-19.

4. **Output layout:**
   ```
   /workspace/training/attr-dataset/
   ├── train/<annotation_id>.jpg   # 224×224, RGB, padded
   ├── val/<annotation_id>.jpg
   ├── manifest.csv
   └── manifest_meta.json
   ```

5. **Documentation:** [ATTRIBUTE_TRAINING_PLAN.md](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md) (SHIPPED, commit e0b4e8b) — Phase 3 handoff documenting dataset scope, expected class imbalance (37:1 regular vs oversized), target metrics (≥0.75 top-1, ≥0.55 macro-F1, ≥0.90 calibration @ conf≥0.80), export contract, and pod runbook.

**Verification:**
- Dataset sanity on pod run: `manifest_meta.total_crops ≥ 40,000`; oversized class survives with ≥400 crops.
- Visualize 20 random samples per class in a notebook cell — no mislabels.

**Next action:** Pod operator — run `prepare_fashionpedia.py` (12 GB download) then `prepare_attribute_dataset.py --out /workspace/training/attr-dataset`. Sanity-check `manifest_meta.json` per training plan § 7 before starting Phase 3.

---

### Phase 3 — Attribute classifier training

**Status:** IN PROGRESS — trainer + evaluator code shipped 2026-04-19; pod GPU run pending Phase 2 dataset materialization. See [ATTRIBUTE_TRAINING_PLAN.md](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md) § 4–5 for the full model / metric contract.
**Track:** C
**Depends on:** Phase 2 dataset (pod)
**Est. effort:** 2 days wall-clock (3–4 hours GPU × ~3 iterations)

**Goal (Option C scope).** Produce a single-head MobileNetV3-Small checkpoint that hits val macro-F1 ≥ 0.55 and top-1 ≥ 0.75 across the 5 fit classes. Target metrics + failure modes documented in [ATTRIBUTE_TRAINING_PLAN.md § 5](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md). Texture head removed — see [BLOCKERS.md#D-2](./2026-04-19-auto-attribute-detection/BLOCKERS.md).

**Changes:**

1. **`notebooks/training/scripts/train_attributes.py`** (SHIPPED):
   - `torchvision.models.mobilenet_v3_small` with ImageNet pretrain (no timm dep — torchvision is already pinned).
   - Single head: `Linear(in=576, out=5)` — `TRAINABLE_FIT_LABELS` count.
   - Loss: `nn.CrossEntropyLoss(weight=class_weights)` with `weights = clip(max / count, 1.0, 10.0)` (P2-3 clamp prevents oversized from fitting to noise).
   - Sampler: `WeightedRandomSampler` with inverse-frequency weights (oversamples rare classes in training; val stays uniform).
   - Optimizer: AdamW, lr 3e-4, weight_decay 1e-4, linear warmup (1 epoch) → cosine decay.
   - Hyperparams: 20 epochs, batch 128, 224×224 input, RandomHorizontalFlip + mild ColorJitter + RandomErasing(p=0.25).
   - Checkpoints: `attr_best.pth` (best val **macro-F1**, not top-1 — majority-class defense), `attr_last.pth`, `attr_metrics.json`, `run_summary.json`.
   - Mixed precision on CUDA (fp32 on CPU and in `--smoke` mode). `GradScaler` persists across epochs.

2. **`notebooks/training/scripts/eval_attributes.py`** (SHIPPED):
   - Row-normalized 5×5 confusion matrix (seaborn heatmap → PNG).
   - Calibration plot: 20-bin reliability diagram with a dotted red line at the 0.80 pre-fill threshold, bubble size ∝ bin count.
   - Markdown-formatted per-class precision/recall/F1/support table to stdout (pasteable into session logs).
   - `summary.json` — machine-readable grade card keying on the conf≥0.80 `realized_acc` metric.

3. **Launch:** pod runbook in [ATTRIBUTE_TRAINING_PLAN.md § 7](./2026-04-19-auto-attribute-detection/ATTRIBUTE_TRAINING_PLAN.md). No shell launcher — just a documented `python train_attributes.py …` command, mirroring the existing `train.py` invocation.

**Verification:**
- `run_summary.best_macro_f1 ≥ 0.55` (shippable floor) — per-class F1 ≥ 0.30 on oversized (rare) / 0.45 on relaxed (second-rarest).
- `summary.high_conf.realized_acc ≥ 0.90` at threshold 0.80 — underwrites the iOS pre-fill threshold (`AttributePrefill.minConfidence = 0.80`).

**Next action:** Pod operator — after Phase 2 dataset lands at `/workspace/training/attr-dataset`, launch a 2-epoch smoke (`--smoke --epochs 2 --batch-size 32`) to prove wiring before committing to 20 epochs × 3 iterations (~10 pod-hrs).

---

### Phase 4 — Core ML export + iOS inference wiring

**Status:** PARTIAL — iOS scaffolding DONE (2026-04-19, `223dcf3`): `AttributeClassifying` protocol, `AttributeClassifierService`, `MockAttributeClassifier`, and the test suite all in place. Exporter `notebooks/training/scripts/export_attribute_classifier.py` shipped (`6d78da2`, Option C single-head, 6-bit palettization, ImageNet normalization + softmax baked into the traced graph, output renamed to `fit_probs`). D-3 single-head decode contract locked (`d829e1f`) — `decodeHandlesSingleHeadFitOnlyOutput` regression test + `fitLabels` shrunk to the 5-class trainable subset (latent shape-mismatch bug fixed before the real mlpackage lands). **Real `AttributeClassifier.mlpackage` is not shipped yet** — depends on Phase 3's trained checkpoint (pod work). Flag-gated (`FeatureFlags.isAttributeDetectionEnabled`, default off, Phase 8 wiring) so the app is ready to consume the package the moment it lands.
**Track:** D
**Depends on:** Phase 3 (at least first checkpoint) — but scaffolding can start earlier with a dummy mlpackage
**Est. effort:** 2 days

**Changes:**

1. **`notebooks/training/scripts/export_attribute_classifier.py`** (NEW):
   - Loads `attr_best.pth`, traces with torch.jit, converts via `coremltools.convert()`.
   - Output shapes: input `image (1,3,224,224) Float16`, outputs `texture_logits (1,15) Float16`, `fit_logits (1,6) Float16`.
   - 6-bit k-means palettization (reuse the helper from `export_coreml.py`).
   - Smoke test: random tensor in → probe shape + dtype → pass.
   - Product: `AttributeClassifier.mlpackage`.

2. **iOS: `WardrobeReDo/Services/Extraction/AttributeClassifierService.swift`** (NEW):
   - Actor / class with `async func predict(crop: UIImage) async throws -> (texture: TextureType?, textureConf: Float, fit: FitAttribute?, fitConf: Float)`.
   - Preprocesses: crop to bbox (already available from `MaskProposal.boundingBox`), resize to 224, normalize to ImageNet mean/std.
   - Decodes: argmax + softmax per head, maps index → enum case via an order-preserving Swift array mirroring the training class order.
   - Protocol `AttributeClassifying` so tests can inject `MockAttributeClassifier` (mirror `MultiGarmentExtracting` pattern).

3. **Hook into `MultiGarmentProposalService`** at [WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift](WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift):
   - After constructing each `MaskProposal`, kick off an `await classifier.predict(crop: cropBox)` call.
   - Populate the new `predictedTexture`, `predictedFit`, and confidences.
   - Single model load + warm-up on first use; subsequent calls reuse.

4. **Bundle the new mlpackage.** Add to Xcode target (xcodegen `project.yml`) alongside `RFDETRSegFashion.mlpackage`.

5. **Feature flag.** `FeatureFlags.isAttributeDetectionEnabled` — default `false` initially; flip to `true` in Phase 9 after dogfood validation. Mirror `isMultiGarmentEnabled` pattern.

6. **Tests** — `WardrobeReDoTests/Services/AttributeClassifierServiceTests.swift`:
   - Shape / dtype smoke (real mlpackage if available, else `MockAttributeClassifier`).
   - Confidence threshold respected (forged 0.5 confidence → no pre-fill).
   - Timeout / error swallow (mirror the pattern in [WardrobeReDoTests/Services/ImageServiceProposalsTests.swift:118](WardrobeReDoTests/Services/ImageServiceProposalsTests.swift:118)).

**Verification:**
- `xcodebuild test` passes.
- Manual sim smoke: 1-garment photo → Add Item details step shows pre-filled texture + fit chips.

**Next action:** Write `AttributeClassifierService.swift` + `AttributeClassifying` protocol + `MockAttributeClassifier` **BEFORE** the real mlpackage lands — lets us wire Phase 6 against the mock.

---

### Phase 5 — Rules engine for seasons + occasions

**Status:** DONE (2026-04-19, `e67d14b`) — `AttributeRulesEngine.derive(...)` ships with exhaustive enum coverage + non-empty invariant + property-based tests. `RULES_TABLE.md` drafted in the artifacts dir.
**Track:** E
**Depends on:** Phase 1 taxonomy (uses `ClothingCategory`, `ClothingSubcategory`, `TextureType`)
**Est. effort:** 1 day (plus ~1h user review of the rules table)

**Goal.** Deterministic, inspectable function `(ClothingCategory, ClothingSubcategory, TextureType?) → (Set<Season>, Set<Occasion>)` that **always returns non-empty sets** (addresses the edge case raised in Q&A).

**Changes:**

1. **`WardrobeReDo/Services/AttributeRules/AttributeRulesEngine.swift`** (NEW):
   ```swift
   enum AttributeRulesEngine {
       static func derive(category: ClothingCategory,
                          subcategory: ClothingSubcategory,
                          texture: TextureType?) -> (seasons: Set<Season>, occasions: Set<Occasion>) {
           let seasons = seasonRule(category, subcategory, texture)
           let occasions = occasionRule(category, subcategory, texture)
           // Invariant: never empty. Fallback to all-seasons / casual.
           return (
               seasons.isEmpty ? Set(Season.allCases) : seasons,
               occasions.isEmpty ? [.casual] : occasions
           )
       }
       // internals below
   }
   ```

2. **Rules table** `WardrobeReDo/Services/AttributeRules/RulesTable.swift`:
   - Expressed as a Swift struct with pattern-match clauses (readable in PRs), not external JSON (keeps compile-time type safety).
   - Example clauses:
     ```swift
     // wool / tweed / leather outerwear → fall + winter
     case (.outerwear, _, .wool), (.outerwear, _, .tweed), (.outerwear, _, .leather):
         return [.fall, .winter]
     // sandals → summer only
     case (.shoe, .sandal, _):
         return [.summer]
     // denim → spring + fall (indoor anytime)
     case (_, _, .denim):
         return [.spring, .fall, .summer]
     ```
   - Full table drafted in `docs/plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md` for user review.

3. **Tests** — `WardrobeReDoTests/Services/AttributeRulesEngineTests.swift`:
   - Every enum combination returns non-empty.
   - Known canonical cases (wool coat → winter, flip-flop → summer, cotton tee → spring+summer+fall, leather dress shoe → all seasons + work/formal).
   - Exhaustiveness: `#expect` coverage hits every `TextureType` case at least once.

**Output artifacts:**
- `RULES_TABLE.md` — the reviewable rules
- Unit test suite that protects them

**Verification:**
- All unit tests green.
- Property-based: for every `(category, subcategory, texture)` triple, both returned sets are non-empty.

**Next action:** Draft `RULES_TABLE.md` with initial rules, get user review, convert to Swift `switch` cases.

---

### Phase 6 — End-to-end pre-fill integration

**Status:** DONE (2026-04-19) — service composition shipped in `f79c540`; `AutoAttributeE2ETests` covers the wiring in `bb8eec7`. The pipeline currently runs against `MockAttributeClassifier` — flipping in the real mlpackage is a Phase 4 follow-up, no integration change.
**Track:** F
**Depends on:** Phase 0, Phase 4, Phase 5
**Est. effort:** 1 day

**Goal.** Single commit that turns on the full pipeline behind `FeatureFlags.isAttributeDetectionEnabled` (default off).

**Changes:**

1. **`MultiGarmentProposalService` per-proposal finalization:**
   - Call `AttributeClassifierService.predict(crop:)` → texture + fit.
   - Call `AttributeRulesEngine.derive(...)` with the predicted (or user-selected fallback) triple → seasons + occasions.
   - Construct `MaskProposal` with ALL predicted fields populated.

2. **`AddItemViewModel.startNextProposal()` — unify** the Phase 0 pre-fill logic with the real predictions. Phase 0 already wired the mechanics; Phase 6 just makes sure the service is delivering real data.

3. **Feature flag default stays `false`** in this phase. Phase 9 flips it after validation.

4. **Integration test** `WardrobeReDoTests/Services/AutoAttributeE2ETests.swift`:
   - Inject `MockMultiGarmentExtractor` + `MockAttributeClassifier`.
   - Feed a known-shape mock proposal through `processImage` → `startNextProposal`.
   - Assert every field on the VM matches expected pre-fills.

**Verification:**
```bash
xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WardrobeReDoTests/AutoAttributeE2ETests
```

**Next action:** Wire the service composition in `AppState` / DI container; ensure `AttributeClassifierService` is constructed once and reused.

---

### Phase 7 — Supabase schema + correction tracking

**Status:** DONE (2026-04-19, `b0d8f45`) — migration `00009_detected_attributes.sql` adds the `JSONB NOT NULL DEFAULT '{}'::jsonb` column; `WardrobeItem` / `NewWardrobeItem` carry the field. `AddItemViewModel.computeAttributeProvenance` (nonisolated static, 12 unit tests) diffs the snapshot vs final values and emits `{"category":"ai"|"user"|"user_changed_from_ai",...}` into the insert payload.
**Track:** F
**Depends on:** Phase 0 (the `detectedAttributes` snapshot on the VM)
**Est. effort:** 1 day

**Changes:**

1. **Migration** `supabase/migrations/00009_detected_attributes.sql`:
   ```sql
   ALTER TABLE wardrobe_items
   ADD COLUMN detected_attributes JSONB DEFAULT '{}'::jsonb;
   COMMENT ON COLUMN wardrobe_items.detected_attributes IS
     'Map of {field_name: "ai" | "user" | "user_changed_from_ai"}.
      Powers correction-rate telemetry for the attribute model.';
   ```

2. **`WardrobeItem` Codable field:** add `detectedAttributes: [String: String]?` with snake_case key.

3. **Save-path diff** in `AddItemViewModel.save(userId:)` at [WardrobeReDo/ViewModels/AddItemViewModel.swift:691](WardrobeReDo/ViewModels/AddItemViewModel.swift:691):
   - Compare `detectedAttributes` snapshot (captured during pre-fill) vs the final user-edited values.
   - Build: `{"category": "ai"|"user"|"user_changed_from_ai", ...}`.
   - Pass through to `NewWardrobeItem` / `WardrobeRepository.create()`.

4. **Analytics hook** (later, out of scope for v1): a Supabase view aggregating correction rates by field for model-quality monitoring.

**Verification:**
- Migration applies cleanly on local Supabase: `supabase db reset`.
- Round-trip test: save an item with 3 pre-filled fields, change 1, fetch back → `detected_attributes == {"category":"ai","texture":"ai","fit":"user_changed_from_ai"}`.

**Next action:** Write the migration, run `supabase db reset` locally to verify clean apply.

---

### Phase 8 — UX polish ("AI detected" indicator)

**Status:** DONE (2026-04-19, `0f446d7`) — `AddItemView` section headers show a `sparkles` SF Symbol badge while the live form value still matches the pre-fill snapshot; any user edit drops the badge on next render with no explicit toggle state. Developer Menu gains an `isAttributeDetectionEnabled` toggle mirroring the multi-garment pattern. `applyPrefill` now short-circuits to the legacy hard-reset when the flag is off. Suite: 551 tests / 13 suites green.
**Track:** F
**Depends on:** Phase 6
**Est. effort:** 0.5 day

**Changes:**

1. **Visual indicator** on pre-filled chips in [WardrobeReDo/Views/Wardrobe/AddItemView.swift:322](WardrobeReDo/Views/Wardrobe/AddItemView.swift:322):
   - Subtle sparkle icon (SF Symbol `sparkles`) or colored tint on pre-filled values.
   - Removed automatically the moment the user interacts with the chip (signals the override).
   - No modal, no toast — non-intrusive.

2. **Developer Menu toggle** for `isAttributeDetectionEnabled` (mirrors the multi-garment toggle).

3. **Accessibility:** `accessibilityLabel("AI suggested: \(value)")` on indicated chips.

**Verification:**
- Sim smoke: pre-filled chip shows sparkle; tapping any option clears the sparkle.
- VoiceOver: labels read correctly.

**Next action:** Design a 2-pixel-wide sparkle affordance + a11y review before implementing.

---

### Phase 9 — Validation + rollout

**Status:** BLOCKED — waiting on Phase 3 training checkpoint + Phase 4 real `AttributeClassifier.mlpackage`. Everything downstream (iOS pipeline, provenance telemetry, sparkle UX, flag gate) is ready to flip once the classifier ships.
**Track:** F
**Depends on:** Phases 6, 7, 8
**Est. effort:** 1–2 days

**Changes:**

1. **Dogfood suite.** Upload 50+ photos (mix: me-wearing, studio shots, full outfits, single flat-lay). Record per-field pre-fill accuracy in `docs/plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md`.

2. **Rule-table iteration.** Parse `detected_attributes` diffs from dogfood saves → update `RULES_TABLE.md` where correction rate exceeds 30%.

3. **Retrain cycle** (optional, only if texture accuracy < 65% on dogfood): one more Phase 3 iteration with class-weighted loss.

4. **Flag flip.** Change `FeatureFlags.isAttributeDetectionEnabled` default `false` → `true` (same pattern as the multi-garment flip in the previous release).

5. **Release notes** in `docs/plans/2026-04-19-auto-attribute-detection.md` (after plan migrates to repo) — user-facing summary for the README.

**Verification:**
- All 461+ existing tests plus ~20 new tests green.
- Real-weights dogfood shows:
  - Category pre-fill ≥90% acceptance (near-zero user changes) — expected since this is already-working model output.
  - Texture pre-fill ≥70% acceptance.
  - Fit pre-fill ≥65% acceptance.
  - Seasons / occasions ≥75% acceptance (rules are easy to tune).
- Crash-free session rate unchanged vs baseline.

**Next action:** Template ready at [DOGFOOD_RESULTS.md](./2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md). Once the trained mlpackage is bundled, queue 50 photos per the composition table, run, fill the "TBD" cells, then decide on flag flip per the Decision checklist.

---

## Open questions (deferred)

Park these for mid-implementation review, not up-front decisions.

1. **Palette preservation.** The existing extraction pipeline captures `dominantColors`. Should the attribute classifier see the masked cutout or the raw bbox? Masked hides background clutter (likely better for textures like knit/silk). Raw preserves context (sometimes helpful for fit judgment: "oversized" often shows extra fabric). **Initial call: use the masked cutout.** Revisit if fit accuracy is weak.
2. **Multi-label attributes.** Fashionpedia sometimes tags a garment with multiple materials (e.g., "cotton/polyester blend"). Do we pick one (argmax) or allow multi-select? iOS `TextureType?` is single today. **Initial call: argmax, keep the Swift type single.** If user correction rate shows this is wrong, revisit with a `textures: Set<TextureType>` schema change.
3. **Regional climate tuning.** User-configurable "warm climate / cold climate" setting that shifts the season rules. Out of scope for v1; capture in a v1.1 punch list.
4. **On-device retraining.** Core ML on-device personalization APIs could re-weight the classifier based on user corrections. Pure research; revisit after 6 months of correction-data collection.

---

## End-to-end verification

Run after Phase 9 lands.

```bash
# 1. Full test suite
xcodebuild test -scheme WardrobeReDo -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -quiet

# 2. Migration smoke
supabase db reset && psql $DB_URL -c "\d wardrobe_items" | grep detected_attributes

# 3. Sim dogfood (manual)
#    - Fresh install, flag ON
#    - Capture a mixed outfit photo (top + bottom + shoe)
#    - Expect: 3 proposals; each details screen shows pre-filled category, texture, fit,
#      seasons, occasions with sparkle indicator
#    - Change 1 field on garment 2
#    - Save all 3
#    - Inspect Supabase: garment 2 should have detected_attributes.texture = "user_changed_from_ai"
```

---

## Critical files table (quick reference)

| Path                                                                  | Phase | What                                                    |
| --------------------------------------------------------------------- | ----- | ------------------------------------------------------- |
| `WardrobeReDo/Models/MaskProposal.swift`                              | 0     | Add 6 new predicted* fields + confidences               |
| `WardrobeReDo/Models/Enums/ClothingCategory.swift`                    | 0     | Add `ClothingSubcategory.fromFashionpediaClass`         |
| `WardrobeReDo/Config/AttributePrefill.swift` (NEW)                    | 0     | `minConfidence`, `shouldPrefill` helper                 |
| `WardrobeReDo/ViewModels/AddItemViewModel.swift`                      | 0, 6, 7 | Pre-fill logic, detectedAttributes snapshot, diff on save |
| `WardrobeReDoTests/ViewModels/AddItemViewModelPrefillTests.swift` (NEW) | 0     | Pre-fill unit tests                                     |
| `notebooks/training/scripts/audit_fashionpedia_attributes.py` (NEW)   | 1     | Inventory CSV dump                                      |
| `docs/plans/2026-04-19-auto-attribute-detection/ATTRIBUTE_TAXONOMY.md` (NEW) | 1 | Fashionpedia → iOS enum mapping                         |
| `notebooks/training/scripts/prepare_attribute_dataset.py` (NEW)       | 2     | Crop + label dataset                                    |
| `notebooks/training/scripts/train_attributes.py` (NEW)                | 3     | MobileNetV3 multi-head trainer                          |
| `notebooks/training/scripts/eval_attributes.py` (NEW)                 | 3     | Confusion matrix + calibration                          |
| `notebooks/training/scripts/export_attribute_classifier.py` (NEW)     | 4     | Torch → Core ML with palettization                      |
| `WardrobeReDo/Services/Extraction/AttributeClassifierService.swift` (NEW) | 4 | Core ML inference wrapper + mock                        |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift`  | 4, 6  | Chain attribute classifier into per-proposal flow       |
| `WardrobeReDo/Services/AttributeRules/AttributeRulesEngine.swift` (NEW) | 5   | `derive(category, subcategory, texture)`                |
| `WardrobeReDo/Services/AttributeRules/RulesTable.swift` (NEW)         | 5     | Pattern-match rules                                     |
| `docs/plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md` (NEW) | 5     | Reviewable rules source                                 |
| `WardrobeReDoTests/Services/AttributeRulesEngineTests.swift` (NEW)    | 5     | Exhaustive rule tests                                   |
| `WardrobeReDoTests/Services/AutoAttributeE2ETests.swift` (NEW)        | 6     | End-to-end integration                                  |
| `supabase/migrations/00009_detected_attributes.sql` (NEW)             | 7     | JSONB column + comment                                  |
| `WardrobeReDo/Models/WardrobeItem.swift`                              | 7     | `detectedAttributes` Codable field                      |
| `WardrobeReDo/Repositories/WardrobeRepository.swift`                  | 7     | Persist detected_attributes                             |
| `WardrobeReDo/Views/Wardrobe/AddItemView.swift`                       | 8     | Sparkle affordance on pre-filled chips                  |
| `WardrobeReDo/Config/FeatureFlags.swift`                              | 4, 9  | `isAttributeDetectionEnabled` flag + Phase 9 flip       |
| `docs/plans/2026-04-19-auto-attribute-detection/DOGFOOD_RESULTS.md` (NEW) | 9 | 50-photo dogfood report                                 |
| `docs/plans/INDEX.md`                                                 | post-approval | Add row pointing at the promoted plan                 |

---

## User request (verbatim)

> I also want our camera to be able to decide what the type of clothing the item is according to the criteria in our app. its category: whether it is a bottom top shoe Dres…. its texture: cotton silk denim leather… fit Oversized Relaxed Regular… seasons: spring summer fall winter occasions: casual work date formal… I want the correct options pre selected after the screen that comes after the camera sequence. And still be changeable by the user in case it detected incorrect. I need you to create a large plan for both the implementation of this in the image process model and training with it extensive research for database and training plan and the implementation inside the app itself the ui changes and the changes I am unable to think of think extensively create a step by step plan that you can go back and continue from where you left off for the probable case that you will forget because of context size limitations think of parallel runnable tasks inside dont forget that the plan that has no token or time limit and you have unlimited access research according to your needs ask me questions that I can understand make sure i can track the progress of this plan creation

Authored 2026-04-19.
