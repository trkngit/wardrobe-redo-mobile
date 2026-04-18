# Wardrobe Re-Do — Multi-Garment Detection (Polished, Multi-Pick)

**Plan slug:** `2026-04-18-multi-garment-detection`
**Status:** IN PROGRESS — iOS plumbing shipped behind flag; blocked on GPU training run for Commit 9 flag-flip
**Estimated cycle time:** 5-7 weeks calendar
**Estimated total cost:** ~$200 GPU + ~$500 engineering tooling subscriptions (Sentry, Roboflow optional)

## Execution log

| Commit | Status | SHA (head of branch) | Notes |
|---|---|---|---|
| 0 — docs/plans seed | shipped | `67a869b` | Plan mirrored into repo, INDEX.md + MEMORY pointer added |
| 1 — FeatureFlags + Debug toggle | shipped | `1581a8d` | UserDefaults-backed flag namespace, default off |
| 3 — MaskProposal + service | shipped | `8ed87c1` | Protocol + mocks + class mapping + tests |
| 4 — ProcessedImage.proposals + ImageService wiring | shipped | `a19fa13` | Parallel pipeline behind flag |
| 5 — MultiGarmentTapToSelectView + snapshots | shipped | `a3bc8ac` | Checkbox UI + "Save N" CTA + "Use full photo" escape |
| 6 — AddItemViewModel batch save loop | shipped | `b9a8841` | Sequential per-item details; actor-based test isolation resolved cross-suite race |
| 7 — Smoke test + ML Diagnostics menu | shipped | `f68f2c7` | DEBUG-only launch smoke test, auto-disables flag on throw; diagnostics view exposes latency/classes/status |
| 8 — FirstRunTutorial copy | shipped | `2455e2f` | Slide 3 rewritten to cover multi-pick |
| 2 — Training notebook scaffold | shipped (scaffold only) | `da243e5` | GPU run deferred; recipe + pins + export pipeline checked in |
| 9 — Flag default-on | **blocked on trained `.mlpackage`** | — | Needs Commit 2's notebook to actually run; see Section 14 |

---

## 0 — Permanent Plan Storage Convention (MUST READ NEXT TIME)

This plan was originally authored in `~/.claude/plans/unified-mapping-honey.md` (the plan-mode scratch area). **That file is overwritten every plan-mode session and should not be considered durable.** All approved plans are mirrored into this repo at `docs/plans/` so they survive context resets, are visible to any future Claude session that reads the repo, and become git-tracked artifacts.

### Convention

```
/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/docs/plans/
├── INDEX.md                                          # one-line summary of every plan
├── 2026-04-18-multi-garment-detection.md             # this plan, post-approval
├── 2026-04-18-multi-garment-detection-research.md    # raw research findings (long-form)
└── archive/                                          # plans that shipped or were abandoned
```

Every plan file has:
- A `## Status` line at the top updated as work progresses
- Footer with the originating user request quoted verbatim and the date
- Cross-links to PRs / commits as they land

### Memory pointer

A one-line pointer lives in `/Users/tarkansurav/.claude/projects/-Users-tarkansurav-Projects-Coding-Wardrobe-Re-Do/memory/MEMORY.md` so the next Claude session in this project auto-loads the path to `docs/plans/INDEX.md` via `CLAUDE.md`. **No plan ever gets lost to context compaction again.**

### What goes here vs in the repo

- Plan-mode scratch (`~/.claude/plans/*.md`) — current draft, ephemeral, overwritten
- Repo `docs/plans/*.md` — source of truth, committed, durable
- This document is the canonical plan; after ExitPlanMode + approval, copy to repo as the first execution step

---

## 1 — Context

User report after device-testing the just-shipped tap-to-select-first flow on a real photo (woman wearing sunglasses, white blazer, brown tshirt under the blazer, and a skirt):

> "the program outlined the person but as you can see she is wearing multiple items like a jacket a glasses and a tshirt inside that jacket ı want these to be seperated in this screen and ask the user on what they want to add if multiple clothings like these are detected"

Today's pipeline (`ImageService.processImage` → `ClothingExtractionService.extract`) runs Vision `VNGenerateForegroundInstanceMaskRequest` and collapses every detected instance via `observation.allInstances` into ONE mask. SAM2 fallback is single-point single-mask. Net result on a clothed-person photo: a single silhouette of the person, with jacket + tshirt + skirt + sunglasses all merged.

Goal: when multiple clothing items are detected in one photo, present each as an independently-selectable, labelled proposal on a new multi-pick screen. User checks the items they want via checkboxes, taps "Save N items", and the app walks them through details for each proposal in sequence.

User-confirmed design decisions (this planning cycle):
- **Path B — polished, label-aware.** Invest in a clothing-aware ML model that returns per-garment instance masks with class labels.
- **Multi-pick batch.** User selects N proposals via checkboxes and saves them all in one go.

User's broader directive on planning quality:
> "I want you to extend the plan do lots of research Find models to train etc... I want you to come up with plans and courses of actions that will reduce the processes of debugging and save both time and token use"

This plan accordingly invests heavily in:
- Research-backed model + dataset + license decisions (Section 2-3)
- Defensive engineering: feature flags, smoke tests, telemetry, snapshot regression (Section 11-12)
- Permanent plan storage so this work doesn't have to be re-discovered next session (Section 0)

Out of scope for v1: brush-based per-proposal editing (existing MaskTouchupView still reachable per-proposal), multi-photo batches, shared-form batch details (we use sequential per-item details).

---

## 2 — Model Selection (Research-Backed)

### Primary recommendation: RF-DETR-Seg-Small fine-tuned on Fashionpedia

**Why this and not the obvious alternatives:**

| Architecture | License of weights | Core ML path | Verdict |
|---|---|---|---|
| **RF-DETR-Seg-Small** (Roboflow) | **Apache 2.0** on Nano/Small/Medium/Large | DETR-style, end-to-end, no RoIAlign or NMS-shape-pain. Roboflow explicitly designs for ANE. Apple ships `coreml-detr-semantic-segmentation` as a reference. | **USE** |
| Mask R-CNN (torchvision) | MIT code | **BROKEN.** `torchvision::roi_align` has no native Core ML op. coremltools issue #2479 still open. Reference repos are 4-6 years old, pre-coremltools 8, require splitting the model into 3 separate `.mlpackage` files with manual Metal+Accelerate glue. | **RULE OUT** |
| Modanet-trained Mask R-CNN | CC BY-NC 4.0 (annotations propagate) | n/a | **RULE OUT** — non-commercial license. Fatal for App Store ship. |
| DeepFashion2-trained models | "research only" — explicitly forbids redistribution | n/a | **RULE OUT** |
| `mattmdjaga/segformer_b2_clothes` | NVIDIA SegFormer non-commercial license | Clean Core ML conversion | **RULE OUT** despite perfect 18-class fit |
| `sayeed99/segformer-b3-fashion` | Same NVIDIA chain | n/a | **RULE OUT** |
| YOLOv8-seg / YOLOv11-seg | **AGPL-3.0** (Ultralytics) — distribution = source obligation | Excellent (Ultralytics ships an iOS app) | **RULE OUT** without paying Ultralytics Enterprise license |
| YOLO-NAS-seg (Deci) | Code Apache 2.0; **pretrained weights "research only"** | Good | **RULE OUT** for pretrained; from-scratch training forfeits the benefit |
| SAM 2 (Meta, Apple's CoreML build) | **Apache 2.0** weights + code | Apple ships `apple/coreml-sam2-{tiny,small,base+,large}` FP16 pre-converted | **USE AS FALLBACK** (class-agnostic, needs a labeling head) |
| SCHP (ATR variant) | MIT code; ATR dataset has no LICENSE file | Conversion path unproven | **RULE OUT** — legal ambiguity on dataset terms |

**RF-DETR-Seg specifics:**
- DETR-style transformer with DINOv2 backbone — no anchors, no NMS, no RoIAlign. Every op maps cleanly to Core ML MIL.
- COCO-pretrained checkpoints; we fine-tune on Fashionpedia.
- Reported (detection variant): 54.7% mAP @ 4.52 ms on T4 GPU.
- Roboflow ships an official Swift SDK targeting Core ML + ANE with FP16 baseline.
- Nano variant should land under 100 MB at FP16; Small under 150 MB.
- Apple has shipped DINOv2-backed models (Depth Anything V2) confirming the backbone architecture maps cleanly to ANE.
- Repo: https://github.com/roboflow/rf-detr — segmentation released in RF-DETR 1.4 (late 2025).

**Backup plan: SAM 2 Tiny + classifier head**
- Apple's `apple/coreml-sam2-tiny` is 38.9 MB, FP16, ANE-optimized, Apache 2.0.
- SAM 2 produces excellent masks but is class-agnostic.
- Layer a small **ResNet-18 classifier** fine-tuned on Fashionpedia crops (~5 MB FP16) to label each mask.
- Total: ~45 MB. Less polished detection (need point/box prompts) but very low integration risk because Apple has done the ANE conversion already.
- Use `VNDetectHumanBodyPose3DRequest` (iOS 17+, iPhone 12 Pro+) to derive shoulder/hip joints as automatic prompts when a person is in the photo. Falls back to grid-of-points for flat-lay garments.

If RF-DETR-Seg fine-tuning misses the latency or accuracy bar after 4 weeks of effort, **fall back to the SAM 2 Tiny + classifier path** rather than fight Mask R-CNN's Core ML conversion.

---

## 3 — Dataset

### Fashionpedia (CC BY 4.0 annotations)

The only large-scale fashion instance segmentation dataset with a clean commercial license.

| Field | Value |
|---|---|
| License (annotations) | **CC BY 4.0** — commercial use OK with attribution |
| License (images) | Most are Creative Commons; CVDF host filters to CC-licensed only |
| Total images | 46,781 |
| Apparel main classes | 27 (jacket, shirt, top, sweater, cardigan, dress, skirt, pants, shorts, coat, vest, jumpsuit, cape, glasses, hat, headband, sock, shoe, bag, scarf, tights, leg warmer, glove, bracelet, ring, watch, belt, etc.) |
| Garment parts | 19 |
| Attributes | 294 |
| Annotation format | COCO-format instance polygons + bboxes |
| Hosted by | CVDF (Common Visual Data Foundation), HuggingFace `detection-datasets/fashionpedia` |

**This is a strict superset of the user's required classes** (jacket, top, skirt, sunglasses) and extends to bonus classes (bag, hat, scarf) Modanet wouldn't have given us.

**Class collapse for v1:** Fashionpedia's 27 classes map to the existing `ClothingCategory` enum's 6 cases. Mapping table is in Section 6.

Sources:
- https://fashionpedia.github.io/home/data_license.html
- https://github.com/cvdfoundation/fashionpedia
- https://huggingface.co/datasets/detection-datasets/fashionpedia

---

## 4 — Training Plan

### Hardware + cost

- **1× NVIDIA A100 40GB** — sufficient for batch 4-8 at 1024×1024
- Provider options:
  - Lambda Labs on-demand: $1.29/hr
  - Vast.ai interruptible: ~$0.79/hr
  - RunPod: $1.39/hr
- Budget for full training cycle (incl. 2-3 hyperparam runs): **~$100-200**

### Training recipe

```
1. Download Fashionpedia from CVDF or HuggingFace
2. Preprocess: convert to RF-DETR's expected COCO format
3. Fine-tune RF-DETR-Seg-Small from COCO checkpoint
   - Epochs: 6-12 (transformers fine-tune in fewer epochs than CNNs)
   - LR: 1e-4 to 5e-5 with cosine decay
   - Batch: 4-8 per GPU at 1024×1024 with mixed precision
   - Wall-clock: ~30-50 GPU hours on 1× A100
4. Evaluate on Fashionpedia val split
   - Target: ≥30 mask mAP @ 0.5 IoU on the 6 collapsed superclasses
   - Per-class breakdown to spot weak spots
5. Iterate (1-2 hyperparam runs typical)
```

### Reproducibility artifact

Training is run in a Jupyter notebook checked into `notebooks/training/2026-04-multi-garment.ipynb` in the project repo. The notebook:
- Pins all dependencies via `requirements.txt`
- Documents seed values for full reproducibility
- Outputs metric snapshots, confusion matrix, sample predictions
- Exports the final `.pth` checkpoint for Core ML conversion

### Data licensing checklist before training

- [ ] Confirm Fashionpedia dataset CC BY 4.0 license file is in the data archive
- [ ] Confirm RF-DETR-Seg-Small weights are downloaded from Roboflow's Apache 2.0 release (not the XL/2XL PML 1.0 variants)
- [ ] Add attribution note to app's About screen: "Garment detection powered by Fashionpedia (Jia et al., 2020)"
- [ ] Add attribution to any model/dataset card we publish

---

## 5 — Core ML Conversion Pipeline

### Direct PyTorch → Core ML (NOT via ONNX)

```python
import torch
import coremltools as ct

# 1. Load the fine-tuned RF-DETR-Seg-Small
model = load_finetuned_rfdetr_seg("checkpoints/best.pth")
model.eval()

# 2. Trace with a representative input
example_input = torch.rand(1, 3, 1024, 1024)
traced = torch.jit.trace(model, example_input)

# 3. Convert to Core ML ML Program
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 1024, 1024),
                         scale=1/255., bias=[0, 0, 0])],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,  # match project floor
    compute_units=ct.ComputeUnit.ALL,
)

# 4. Quantize to 6-bit palettization (matches existing SAM2 config)
from coremltools.optimize.coreml import (
    OpPalettizerConfig, OptimizationConfig, palettize_weights
)
palettize_config = OpPalettizerConfig(
    nbits=6, mode="kmeans", granularity="per_grouped_channel", group_size=16
)
mlmodel_compressed = palettize_weights(
    mlmodel, OptimizationConfig(global_config=palettize_config)
)

# 5. Save
mlmodel_compressed.save("RFDETRSegFashion.mlpackage")
```

### Output design (fixed-shape for ANE residency)

DETR architectures naturally output a fixed N (e.g., 100 query tokens), so:

```
Outputs:
  - boxes:        [1, 100, 4]      # cxcywh normalized
  - class_logits: [1, 100, 6]      # 6 collapsed classes (see Section 6)
  - mask_logits:  [1, 100, 256, 256]  # downsampled per-instance masks, sigmoid in Swift
  - validity:     [1, 100]         # objectness score, threshold in Swift
```

The Swift wrapper post-processes:
1. Sigmoid the validity scores → keep boxes with score > 0.5
2. Argmax class_logits per instance → predicted category
3. Sigmoid + threshold mask_logits at 0.5 → binary mask
4. Bilinear upsample mask 256×256 → source-image resolution
5. Composite mask × source image → `MaskProposal.maskedImage`

**Why fixed-shape:** Core ML's Apple Neural Engine requires static shapes for residency. Returning a variable N would force CPU/GPU fallback and lose the latency win. The Swift-side filter on `validity` makes the variable-N reality felt at the API boundary, not in the graph.

### ANE residency verification

Before shipping the model, run in Instruments → Core ML template:
- [ ] Backbone (DINOv2) ops show on ANE compute lane
- [ ] Decoder transformer ops show on ANE
- [ ] Mask head convs show on ANE
- [ ] Total inference under 1.5 s on iPhone 13 (target <1.0 s on iPhone 15)

If anything falls back to CPU/GPU, investigate the offending op and rewrite (replace `Linear` with `Conv2d` 1×1, ensure FP16 throughout, eliminate dynamic shapes).

### Compression target

Following the existing SAM2 pattern: **6-bit palettized `per_grouped_channel`**.

| Stage | Expected size |
|---|---|
| FP32 baseline | ~250 MB |
| FP16 | ~125 MB |
| 6-bit palettized | **~30-50 MB** ← ship target |
| 4-bit palettized | ~20 MB (likely visible mask-edge degradation — skip for v1) |

If 6-bit comes in <30 MB, we can ship inside the bundle. If it's 50+ MB, deliver via Background Assets framework (Section 9).

---

## 6 — Data Model + Service Architecture

### `MaskProposal` struct

New file `WardrobeReDo/Models/MaskProposal.swift`:

```swift
struct MaskProposal: Identifiable, Sendable, Hashable {
    let id: UUID
    let maskedImage: UIImage              // composited cutout, used for thumbnail + final save
    let mask: CVPixelBuffer?              // raw mask, kept for refine-with-brush detour
    let confidence: ExtractionConfidence  // existing enum: .high, .medium, .low, .failed
    let predictedCategory: ClothingCategory?  // existing enum
    let boundingBox: CGRect               // normalized [0,1] in source-image space
    let detectionScore: Float             // raw model objectness, used for display ordering and proposal cap
    let modelClassRaw: String             // raw Fashionpedia class, kept for telemetry
}
```

### `MultiGarmentExtracting` protocol

New file `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift`:

```swift
protocol MultiGarmentExtracting: Sendable {
    func detectProposals(in image: UIImage) async throws -> [MaskProposal]
    func prewarm() async
}
```

Production `MultiGarmentProposalService` mirrors the `SAM2Extractor` loading pattern: `Bundle.main.url(forResource:withExtension:)` + `MLModel(contentsOf:configuration:)`, with `modelLoadAttempted`/`NSLock` guard so first-use racing is safe. Graceful fallback: when the model file is missing (LFS content not yet pulled, Background Assets still downloading), the service throws `MultiGarmentError.modelLoadFailed` and ImageService catches → `proposals: nil` → existing single-item flow runs.

### Class mapping (Fashionpedia → ClothingCategory)

Add static helper to `WardrobeReDo/Models/Enums/ClothingCategory.swift`:

```swift
extension ClothingCategory {
    /// Maps a Fashionpedia main-class string to the app's existing 6-case enum.
    /// Returns nil for classes we don't surface in v1 (e.g., garment parts, attributes).
    static func fromFashionpediaClass(_ raw: String) -> ClothingCategory? {
        switch raw {
        case "shirt_blouse", "top_t-shirt_sweatshirt", "sweater", "vest", "cardigan":
            return .top
        case "pants", "shorts", "tights_stockings":
            return .bottom
        case "skirt":
            return .bottom  // (or .skirt if enum gets refactored — see punch list)
        case "dress", "jumpsuit":
            return .dress
        case "coat", "jacket", "cape":
            return .outerwear
        case "shoe", "boot", "sandal":
            return .shoe
        case "glasses", "sunglasses", "hat", "headband", "scarf", "tie",
             "bag_wallet", "belt", "glove", "watch", "ring", "bracelet",
             "earring", "necklace":
            return .accessory
        case "sock", "leg_warmer", "umbrella":
            return nil  // not surfaced in v1
        default:
            return nil
        }
    }
}
```

**Don't add new enum cases in v1.** The blast radius is high (every reference of `ClothingCategory` + Supabase migration to expand the CHECK constraint). Punch-list item: split `.accessory` into `.bag`, `.eyewear`, `.hat`, `.jewelry` in v1.1 with a coordinated migration.

### Extending `ProcessedImage`

Add `proposals: [MaskProposal]?` (nil = detection skipped/failed; count≤1 = single-item flow).

### Pipeline integration

`ImageService.processImage` runs both extractors in parallel. Single-mask path is the compatibility default; the multi-path adds proposals when the flag is on and the model succeeds.

Backwards compat: `proposals == nil || proposals.count <= 1` → existing single-item TapToSelectView flow runs unchanged.

---

## 7 — Feature Flag Infrastructure

Lightweight UserDefaults-backed flags + a static `FeatureFlags` namespace:

```swift
@MainActor
enum FeatureFlags {
    private static let store = UserDefaults.standard
    private static let logger = Logger(subsystem: "com.wardroberedo", category: "FeatureFlags")

    /// Multi-garment detection master switch.
    /// Default: false (gated rollout), flip via Debug menu or remote-config in future.
    static var isMultiGarmentEnabled: Bool {
        get { store.bool(forKey: "feature.multiGarment.enabled") }
        set {
            store.set(newValue, forKey: "feature.multiGarment.enabled")
            logger.info("FeatureFlag.multiGarment toggled: \(newValue)")
        }
    }
}
```

A Debug menu item (`Profile → Developer → Multi-Garment Detection`) toggles this for QA without rebuilds.

**No remote-config service in v1.** UserDefaults is enough for kill-switch purposes since users update via App Store anyway.

---

## 8 — UI Design: MultiGarmentTapToSelectView

### Decision: separate view, not extending TapToSelectView

The multi-pick UI has fundamentally different state (selection set, "Save N" CTA, per-proposal category chips, render-order rules). Conditionally rendering both modes inside the existing `TapToSelectView` would balloon it. Separation also keeps existing single-item touchpoints (refine-with-brush detour, "Use this crop") untouched.

### Behavior summary

- **Default selection state:** all proposals start selected. Uncheck is faster than check-all.
- **Cap + overflow:** show top 5 proposals by `detectionScore`. If 6+ proposals exist, surface a "+N more" button that opens a sheet listing the rest.
- **Render order:** largest bounding box first (back), smallest last (front). Keeps accessories from getting buried under outerwear.
- **"Use full photo" escape hatch:** always-visible toolbar action. Skips multi-pick and falls through to the existing single-item TapToSelectView. Telemetry-logged so we can measure how often users escape.

---

## 9 — Model Delivery Strategy

| Compressed size | Delivery |
|---|---|
| <30 MB | Bundle in app (current SAM2 pattern, simplest) |
| 30-100 MB | Bundle if total app size stays <200 MB; else Background Assets |
| 100+ MB | **Background Assets framework (iOS 16+) — Apple-hosted variant from WWDC25** |

### If Background Assets is needed

1. Mark the model as an essential asset in `BackgroundAssets.json`
2. Apple hosts the binary on their CDN (no infra to maintain)
3. iOS downloads in background after install, before first launch
4. UX at first launch (if download still in flight): one-time "Preparing AI model" progress sheet
5. Fallback: if the model isn't downloaded yet, feature is silently disabled; single-item flow runs

### Compilation + caching

`.mlpackage` → `MLModel.compileModel(at:)` once → cache resulting `.mlmodelc` in `Application Support/`. Subsequent launches skip the compile.

---

## 10 — Save Loop (Sequential Per-Item Details)

### Decision: sequential, not shared multi-row form

Sequential reuses every line of existing details code and the existing per-capture loop infrastructure (`savedItemsFromSource`, `resetKeepingSource`, `selectedImage`, `sourcePhotoId`). The "batch" feeling comes from automating the user's "Save & add another" choice.

### Flow

1. User taps "Save N items" on multi-pick screen
2. AddItemViewModel sets `pendingProposalQueue = selectedProposals.sorted(by: detectionScore)`
3. Pop first proposal → `currentProposal = proposal` → splice into `processedImage` → `currentStep = .details` → dismiss multi-pick cover
4. User fills details, hits Save → existing save path executes, `savedItemsFromSource += 1`
5. After save, if queue not empty: pop next → set `currentProposal` + `processedImage` again → `currentStep = .details`
6. Queue empty → route to existing post-save state

### Mid-batch escape

Details step gets a "Skip this item" toolbar action (only visible when `pendingProposalQueue.isEmpty == false`). Drops current proposal, pops next. If queue is empty after skip, treats like normal post-save.

---

## 11 — Files to Create / Modify

### New
| File | Purpose |
|------|---------|
| `WardrobeReDo/Config/FeatureFlags.swift` | UserDefaults-backed flag namespace |
| `WardrobeReDo/Models/MaskProposal.swift` | Identifiable struct for one detected proposal |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | Core ML wrapper + post-processing |
| `WardrobeReDo/Views/Camera/MultiGarmentTapToSelectView.swift` | N-proposal checkbox UI with "Save N" CTA |
| `WardrobeReDo/Views/Profile/DeveloperMenuView.swift` | Debug-menu toggle + ML diagnostics |
| `WardrobeReDo/Models/CoreML/RFDETRSegFashion.mlpackage` | Trained model (or via Background Assets) |
| `WardrobeReDoTests/Services/MultiGarmentProposalServiceTests.swift` | Fixture-based detection tests |
| `WardrobeReDoTests/Fixtures/Extraction/multi_garment_manifest.json` | Expected proposal counts + classes per fixture |
| `WardrobeReDoTests/Fixtures/Extraction/multi/*.jpg` | 4-6 reference photos |
| `notebooks/training/2026-04-multi-garment.ipynb` | End-to-end reproducible training notebook |
| `notebooks/training/README.md` | How to reproduce the training run |

### Modified
| File | Change |
|------|--------|
| `WardrobeReDo/Services/ImageService.swift` | Extend `ProcessedImage` with `proposals` field; call `MultiGarmentProposalService.detectProposals` in parallel with single-mask path; gated on `FeatureFlags.isMultiGarmentEnabled` |
| `WardrobeReDo/Services/Extraction/ClothingExtractionService.swift` | Add `.multiGarmentRFDETR` case to `ExtractionMethod` enum |
| `WardrobeReDo/Models/Enums/ClothingCategory.swift` | Add `fromFashionpediaClass(_:)` mapping helper |
| `WardrobeReDo/ViewModels/AddItemViewModel.swift` | Add proposals/selection/queue state; multi-pick handlers; batch save loop wiring; `multiGarmentLoadTask` cancellation |
| `WardrobeReDo/Views/Wardrobe/AddItemView.swift` | Add multi-pick fullScreenCover; conditional "Skip this item" toolbar on details step |
| `WardrobeReDo/Views/Wardrobe/FirstRunTutorialView.swift` | Update slide 3 copy to mention multi-pick |
| `WardrobeReDo/Views/Profile/ProfileView.swift` | Add Developer menu entry (debug builds only) |
| `WardrobeReDoTests/Helpers/Mocks.swift` | Add `MockMultiGarmentExtractor` |
| `WardrobeReDoTests/ViewModels/AddItemViewModelTests.swift` | New tests for multi-pick state, queue progression, skip, single-proposal fallback, feature-flag-off |

Reused (no structural change):
- `TapToSelectView` — existing single-item path runs unchanged for ≤1 proposal
- `MaskTouchupView` — still reachable per-proposal via the existing brush detour
- Existing `save()` path — multi-pick layers on top by re-entering details after save
- `os.Logger` with subsystem `com.wardroberedo` — new categories: `MultiGarment`, `FeatureFlags`

---

## 12 — Debugging + Token-Reduction Strategies

The user explicitly asked: *"come up with plans and courses of actions that will reduce the processes of debugging and save both time and token use."* Here's how this plan minimizes future debug cycles:

### 12.1 Test-first for every commit
Every commit starts with a failing test that codifies the expected behavior. Tests catch regression in seconds without reloading the entire codebase context.

### 12.2 Snapshot tests for mask output
Use `swift-snapshot-testing` to lock down per-fixture mask output. Visual regressions catch model behavior drift that unit tests miss.

### 12.3 Performance budgets enforced in CI
Add `multiGarmentInferenceLatency` to the existing `ExtractionPerformanceTests` rig with a hard budget: p95 < 1.5 s on iPhone 14 reference device.

### 12.4 Structured logging at every async boundary
`Logger(subsystem: "com.wardroberedo", category: "MultiGarment")` with OSSignposter intervals for each inference. Console.app filter `subsystem:com.wardroberedo category:MultiGarment` shows the entire inference history without re-asking for repro steps.

### 12.5 Detailed error types
`MultiGarmentError` with `modelLoadFailed(underlying:modelPath:)`, `inferenceFailed(underlying:)`, `preprocessingFailed(reason:)`, `noValidPredictions(rawCount:threshold:)`. Error string alone is enough to diagnose.

### 12.6 Reproducible PoC notebook
The training notebook is checked in. Future model rebuilds bisect against a known baseline. No "I trained it on my laptop somewhere" black box.

### 12.7 Diagnostic debug menu
`Profile → Developer → ML Diagnostics` shows last inference latency, compute unit (ANE/GPU/CPU inferred), model version + hash, feature flag state, last-10 proposals' raw class scores.

### 12.8 Reference-image fixture promotion
Every reported bug photo gets added to `WardrobeReDoTests/Fixtures/Extraction/multi/` as a permanent regression test. Repo grows fixtures monotonically.

### 12.9 Smoke test at app launch
On every debug-build app launch, run a single inference on a known fixture in the background and assert mask matches expected within tolerance. If mismatch → log loud error + disable the feature flag.

### 12.10 Permanent plan storage (Section 0)
This plan goes into `docs/plans/`. Next time work resumes, INDEX.md surfaces every decision already made.

### 12.11 Single source-of-truth for class mapping
Fashionpedia → ClothingCategory map lives in **one file**. Tests assert every Fashionpedia class either maps to a category or is explicitly nil.

### 12.12 Cancellation discipline
Match the existing `sessionLoadTask` / `processingTask` cancellation pattern. New `multiGarmentLoadTask` cancels on new photo + on `reset()`. Memory bounded → no OOM crashes to debug.

### 12.13 Sentry integration (optional, defer to v1.1)
If `os.Logger` proves insufficient for production debugging, add Sentry SDK with an ML-aware transaction wrapping `detectProposals`. v1 ships on `os.Logger` only.

---

## 13 — Verification

### 13.1 Unit / integration

| Test | Asserts |
|---|---|
| `multiGarmentServiceReturnsExpectedProposalsForFixture` | Feed fixture photos, assert proposal counts ± tolerance + predicted categories |
| `multiGarmentServiceReturnsEmptyOnNoDetection` | Blank background → `[]` (no false positives) |
| `multiGarmentServiceFallsBackGracefullyOnModelLoadFailure` | Mock loader returns nil → `detectProposals` throws `.modelLoadFailed`, ImageService catches, sets `proposals: nil` |
| `addItemMultiPickQueueProgressesThroughDetails` | Set `proposals = [3 items]`, simulate confirm + save × 3; assert `currentProposal` cycles and queue empties |
| `addItemMultiPickAllowsSkip` | Mid-batch skip advances to next without saving |
| `addItemSingleProposalFallsThroughToExistingFlow` | `proposals = [one]` → single-item flow |
| `addItemNoProposalsFallsThroughToExistingFlow` | `proposals = nil` → single-item flow |
| `addItemFeatureFlagOffSkipsMultiPickEntirely` | Flag off + many proposals → single-item flow |
| `addItemUseFullPhotoEscapeRoutesToSingleItemFlow` | `onMultiPickUseFullPhoto` → single-item flow |
| `clothingCategoryMapsAllFashionpediaClassesOrExplicitlyNil` | Every Fashionpedia class maps or is explicitly nil |

### 13.2 IoU regression

Extend existing `SegmentationIoUTests` rig with `multi_garment_manifest.json`. 4-6 fixture photos covering single garment on hanger, single flat-lay, person wearing 2 items, person wearing 4+ items (user's reported case), partial occlusion. Per-proposal IoU > 0.7 vs ground truth.

### 13.3 Snapshot regression

Render each multi-pick fixture in `MultiGarmentTapToSelectView`, snapshot at iPhone 15 Pro resolution with 2% pixel tolerance.

### 13.4 Performance

`multiGarmentInferenceLatency` in `ExtractionPerformanceTests`. p95 < 1.5 s on iPhone 14, < 2.0 s on iPhone 12. Peak resident memory < 250 MB during multi-pick + batch save.

### 13.5 Manual on device

- User's exact reported photo (sunglasses + jacket + tshirt + skirt): ≥3 proposals with category chips, multi-pick CTA, sequential details save.
- Edge cases: single item → single-item flow; 6+ items → top 5 + "+more" sheet; mid-batch skip; force-quit mid-batch; feature flag off; model not yet downloaded.

### 13.6 Regression

All existing 372+ tests stay green — single-item flow unchanged for ≤1 proposal or feature flag off. 27-fixture IoU rig and `ExtractionPerformanceTests` untouched.

---

## 14 — Commit Sequence

Each commit is small, reversible, and shipped behind the feature flag (default OFF).

### Commit 0: Permanent plan storage
**`chore(docs): seed docs/plans index + multi-garment-detection plan`**
- Create `docs/plans/INDEX.md`
- Copy approved plan to `docs/plans/2026-04-18-multi-garment-detection.md`
- Copy research artifacts to `docs/plans/2026-04-18-multi-garment-detection-research.md`
- Update `~/.claude/.../memory/MEMORY.md` with pointer

### Commit 1: Feature flag scaffold
**`feat(config): UserDefaults-backed feature flag namespace`**
- New `FeatureFlags.swift`
- Tests: round-trip + default values

### Commit 2: Training notebook (scaffold; training runs separately)
**`feat(ml): add Fashionpedia training notebook + README`**
- `notebooks/training/2026-04-multi-garment.ipynb`
- `notebooks/training/README.md` documenting data prep + training reproducibility
- (Model artifact lands in a follow-up once GPU run completes)

### Commit 3: MultiGarmentProposalService + MaskProposal + class mapping
**`feat(extraction): MultiGarmentProposalService loads RF-DETR-Seg + returns MaskProposals`**
- `MaskProposal.swift`
- `MultiGarmentProposalService.swift` + `MultiGarmentExtracting` protocol
- `MockMultiGarmentExtractor` in `Helpers/Mocks.swift`
- Service-level fixture tests against 3-4 known photos
- `ClothingCategory.fromFashionpediaClass(_:)` + tests
- Error type `MultiGarmentError`
- Logging on every async boundary

### Commit 4: Proposals through ProcessedImage
**`feat(image): expose proposals via ProcessedImage`**
- Extend `ProcessedImage` with `proposals: [MaskProposal]?`
- Wire `MultiGarmentProposalService` into `ImageService.processImage`
- Gate on `FeatureFlags.isMultiGarmentEnabled`
- Add `.multiGarmentRFDETR` to `ExtractionMethod`
- Tests for both flag states

### Commit 5: MultiGarmentTapToSelectView
**`feat(camera): MultiGarmentTapToSelectView with checkbox proposals`**
- New view with N-proposal overlay, color-cycled tints, category chips
- "Save N" CTA (pluralized)
- "Use full photo" escape

### Commit 6: AddItemViewModel batch wiring
**`feat(wardrobe): batch save loop for selected proposals`**
- AddItemViewModel queue + handlers
- AddItemView wires the new `.fullScreenCover` + Skip toolbar action
- Routing logic: `applyProcessed*` checks proposal count and routes
- Tests for queue progression, skip, fallback to single-item, feature-flag-off

### Commit 7: Smoke test + diagnostic menu
**`feat(diagnostics): app-launch smoke test + ML diagnostics menu`**
- Background smoke test on debug builds
- `Profile → Developer → ML Diagnostics` view

### Commit 8: Onboarding update
**`docs(tutorial): mention multi-pick in slide 3`**

### Commit 9: Enable feature flag default (FINAL — only after model ships)
**`feat(wardrobe): enable multi-garment detection by default`**
- Flip `FeatureFlags.isMultiGarmentEnabled` default to `true`
- Update INDEX.md plan status to "SHIPPED"

---

## 15 — Risks & Mitigations

| # | Risk | Probability | Mitigation |
|---|------|------|-----|
| 1 | Fashionpedia annotations contain non-CC-licensed images we can't redistribute | Low | We ship the MODEL, not the dataset. Model is a derivative work — CC BY 4.0 allows commercial derivatives with attribution. Add attribution to About screen. |
| 2 | RF-DETR-Seg-Small fine-tune doesn't hit 30 mAP target | Medium | Try Medium variant; fall back to SAM 2 + classifier path (Section 2 backup) |
| 3 | RF-DETR-Seg Core ML conversion has op-mapping issues | Medium | Apple ships a reference DETR Core ML model as proof-of-concept. Budget 1 week of buffer. Fall back to SAM 2 path if needed. |
| 4 | Compressed model doesn't fit under 100 MB | Medium | Background Assets framework (Section 9) |
| 5 | Inference too slow on iPhone 12 (A14) | Medium | Downsample input to 768×768 or 512×512 on older devices. Document min device in App Store listing. |
| 6 | Multi-pick UX overwhelming with 5+ proposals | Low | Cap at 5 by score, "+N more" sheet for the rest |
| 7 | Batch save mid-flow crash leaves partial saves | Low | Each save is atomic — partial batch = some saved, none corrupted. v1.1: persist queue to SwiftData for crash recovery |
| 8 | Model returns 0 proposals on clearly-clothed photo | Low | `proposals == []` → single-item flow runs. Smoke test catches this at launch. |
| 9 | Overlapping bboxes ambiguous to tap | Low | Render largest-to-smallest (back-to-front). Tap routes to smallest containing bbox. |
| 10 | "Use full photo" escape silently regresses users | Low | Telemetry log. >20% usage → UX needs rework before hiding escape. |
| 11 | `ClothingCategory` enum lacks `.bag`, `.eyewear`, `.hat` | Known | Fold into `.accessory` for v1. Punch-list item for v1.1 with Supabase migration. |
| 12 | Future-Claude can't find this plan | Mitigated | Section 0 storage convention + MEMORY.md pointer |
| 13 | Background Assets download fails / offline at first launch | Low | Single-item flow runs. One-time "AI features need a download" banner in Settings. |
| 14 | Sentry/analytics SDK adds privacy concerns | Low | Defer Sentry to v1.1. v1 uses `os.Logger` only. |
| 15 | Model misclassifies frequently | Medium | User can correct on details step. Telemetry log (predicted vs final) feeds v1.1 confusion matrix. |

---

## 16 — Punch List (Post-Merge)

- **v1.1:** Refactor `ClothingCategory` — split `.accessory` into `.bag`, `.eyewear`, `.hat`, `.jewelry` with coordinated Supabase migration
- **v1.1:** Persist `pendingProposalQueue` to SwiftData for crash recovery mid-batch
- **v1.1:** User-trainable category corrections — log predicted vs corrected category, surface as v1.2 fine-tune dataset
- **v1.1:** Sentry integration if `os.Logger` proves insufficient
- **v1.1:** Shared multi-row details sheet as a power-user mode (alternative to sequential)
- **v1.1:** A/B test default-all-selected vs default-none-selected on multi-pick
- **v1.1:** Auto-suggest sub-categories from Fashionpedia's 294 attributes
- **v1.2:** Replace Vision foreground mask with the multi-garment model if it proves more robust on flat-lay garments — eliminates dual-pipeline complexity

---

## 17 — Source Material

Full research artifacts in `docs/plans/2026-04-18-multi-garment-detection-research.md`.

**Models + datasets:**
- [RF-DETR repo](https://github.com/roboflow/rf-detr) — Apache 2.0
- [RF-DETR-Seg blog](https://blog.roboflow.com/rf-detr-segmentation/)
- [Fashionpedia data license (CC BY 4.0)](https://fashionpedia.github.io/home/data_license.html)
- [Fashionpedia CVDF host](https://github.com/cvdfoundation/fashionpedia)
- [Apple CoreML SAM 2 collection](https://huggingface.co/collections/apple/core-ml-segment-anything-2)
- [Apple coreml-detr-semantic-segmentation](https://huggingface.co/apple/coreml-detr-semantic-segmentation)
- [ModaNet LICENSE (CC BY-NC 4.0 — RULE OUT)](https://github.com/eBay/modanet/blob/master/LICENSE)

**Core ML + iOS deployment:**
- [coremltools Issue #2479 — Mask R-CNN RoIAlign blocker](https://github.com/apple/coremltools/issues/2479)
- [Apple Background Assets framework](https://developer.apple.com/documentation/backgroundassets)
- [WWDC25 Apple-Hosted Background Assets](https://developer.apple.com/videos/play/wwdc2025/325/)
- [Core ML Palettization Overview](https://apple.github.io/coremltools/docs-guides/source/opt-palettization-overview.html)

**Codebase patterns:**
- `WardrobeReDoTests/Helpers/Mocks.swift` — Mock pattern reference
- `WardrobeReDoTests/Services/SegmentationIoUTests.swift` — IoU rig to extend
- `WardrobeReDoTests/Services/ExtractionPerformanceTests.swift` — perf budget pattern
- `WardrobeReDo/Services/Extraction/ClothingExtractionService.swift` (lines 110-199) — service shape to mirror
- `WardrobeReDo/Services/Extraction/SAM2Extractor.swift` (lines 124, 131-133, 182-187) — model loading pattern
- `WardrobeReDo/ViewModels/AddItemViewModel.swift` (lines 93-101, 140) — `Task` cancellation + DI patterns

---

## 18 — User Request (Verbatim)

> "the program outlined the person but as you can see she is wearing multiple items like. a jacket a glasses anda tshirt inside that jacket ı want these to be seperated in this screen and ask the user on what they want to add if multiple clothings like these are detected how can we achieve this"

> "I want you to extend the plan do lots of research Find models to train etc. Also since we will be running out of context sizes during these I want you to save the plans you make from now on in a permanent way for you to later on check to decide what to do what to plan While you have no time or token limits i still want you to come up with plans and courses of actions that will reduce the processes of debugging and save both time and token use find ways to acvhieve whether through way of action or testing you decide i dont know For this plan you have unlimited resources and time create the best version you can"

Date: 2026-04-18
Plan author: Claude (Sonnet) in plan mode for the Wardrobe Re-Do project
