# Wardrobe Re-Do — Build 5: Critical Capture-Pipeline + Display Rework

> Generated 2026-04-26 from build-4 dogfood (10 screenshots) + 9 parallel agents + Supabase production data audit + web research on color science / iOS isolation / wardrobe app UX.

## Context

TestFlight 1.0.0 (4) — shipped today at 17:29. The user multi-picked 6 items from one mirror selfie. Result:
- All 6 form pre-fills had wrong predictions (sneakers→Boots, jeans→Shorts, sunglasses+belt→Hat, layered tops→single T-shirt)
- Texture not pre-filled on any of the 6 items
- Color palettes show 5 nearly-identical shades on every item (some include skin tone)
- Wardrobe grid renders the multi-pick items with the source-photo backdrop instead of clean cutouts
- Match tab + Outfit cards have the same source-photo backdrop bug (PR #20's fix only covered Wardrobe grid)
- Two outfit cards render visually identical because two "Boots" items exist in DB (wide-shot + close-up of same shoe)

**Severity:** Build 4 visibly regresses on the wardrobe display (vs build 3) AND ships several P0 ML-prediction bugs that PR #19 attempted to fix but didn't. **Build 5 is required before broader TestFlight invitation.**

## Workstream Map

| WS | Title | Severity | Owner Lane |
|---|---|---|---|
| WS-1 | Capture pipeline: real per-garment masking | BLOCKER | Backend / ML |
| WS-2 | Display layer normalization (4 views) | HIGH | Frontend |
| WS-3 | Subcategory mapping fixes (sneakers/sunglasses/belt) | BLOCKER | Backend |
| WS-4 | Texture rules firing for multi-pick | BLOCKER | Backend |
| WS-5 | Color extraction overhaul (LAB + merge + alpha) | BLOCKER | Backend |
| WS-6 | Multi-pick UX (bulk-confirm, progressive disclosure) | HIGH | Frontend / Design |
| WS-7 | Worn Outfits entity + view | MEDIUM | Full-stack |
| WS-8 | Shoe redundancy v2 (proximity-based merge) | HIGH | Backend |
| WS-9 | Telemetry: log raw model classes + confidences | LOW | Backend |
| WS-10 | Item card uniform white-bg layout | HIGH | Frontend |

## Critical findings from production audit

### Multi-pick "masked image" is rect-crop, not cutout
- `MultiGarmentProposalService.cropped()` returns `UIImage(cgImage: cropped, ...)` — a **rectangular slice of the source photo**, NOT a transparent-bg cutout.
- This rect-crop becomes `MaskProposal.maskedImage`, gets uploaded as `masked.png`.
- Wardrobe card rendering displays this rect-crop → user sees the source-photo backdrop.
- **Pre-build-3 single-item flow used Vision+SAM2** which produces real cutouts → why old saves look clean.
- Multi-pick has NEVER produced real cutouts. The visual regression is just becoming visible now because the user did a 6-item multi-pick.

### Subcategory rescue logic is inverted for accessories
PR #19's logic:
```swift
if let sub = proposal.predictedSubcategory, sub.category == category {
    subcategory = sub  // ← .hat default from upstream wins
} else if category == .accessory, let rescue = ... {
    subcategory = rescue  // ← never reached
}
```
The model emits SOMETHING (probably .hat as accessory default), so the first branch always wins. Need to invert the logic for accessories specifically.

### Color extraction picks shadow regions as dominant
First-color analysis of build-4 items:
- 4 of 6 first-colors have lightness < 0.32 (shadow-dominated)
- 4 of 6 first-colors have saturation < 0.13 (very desaturated)
- "Blue jeans" first color is `#332E2C gray hue 20°` — that's NOT blue, it's the shadow under the belt
- The actual blue is at higher lightness, lower in the cluster ranking

K-means in RGB picks shadow as dominant because shadows take up significant pixel area in real-world garment photos.

## Detailed Plan Per Workstream

### WS-1: Real per-garment masking for multi-pick

**Problem:** `MaskProposal.maskedImage` is a rect crop. Need to produce a real transparent-bg cutout per garment.

**Files:**
- `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` (lines 933-946 `cropped()`, line 786 `makeProposal`)
- `WardrobeReDo/ViewModels/AddItemViewModel.swift` (line 960 `startNextProposal()`)

**Approach options:**

**Option A — Use RFDETR-Seg's instance mask (preferred):** Modify `MultiGarmentProposalService` to consume RFDETR-Seg's per-instance segmentation mask (the model is segmentation, not just detection). Apply mask to source image to produce transparent-bg PNG. Replace `cropped()` with `cutout(sourceImage:mask:)`.

**Option B — Vision per-bbox (fallback):** After RFDETR produces bboxes, run `VNGenerateForegroundInstanceMaskRequest` on each bbox region. iOS 17+ only. Slower (one Vision pass per item) but reliable.

**Option C — Skip masked PNG entirely:** Set `maskedData: nil` in `startNextProposal` so ItemCardView falls back to thumbnailPath. Wardrobe shows source-photo thumbnail consistently. Worse visual but consistent and unblocks shipping.

**Recommendation:** Ship Option C in build 5.1 (1-line fix). Land Option A in build 5.2 (proper per-garment masks).

### WS-2: Display layer normalization

**Files:**
- `WardrobeReDo/ViewModels/MatchingViewModel.swift:173`
- `WardrobeReDo/ViewModels/OutfitViewModel.swift:350, 359`

**Change:** All three call sites change `for: item.thumbnailPath` → `for: ItemCardView.displayPath(for: item)`. Mirror PR #20's WardrobeViewModel pattern.

**Affected views (rendered correctly after fix):**
- `MatchingView::heroItemCell` (line 89) — match tab piece selector
- `MatchResultCard::itemThumbnail` (line 72) — match outfit suggestions
- `OutfitCardView::itemThumbnail` (line 87) — outfits feed
- `OutfitDetailView::itemCard` (line 107) — outfit detail

### WS-3: Subcategory mapping fixes

**Files:**
- `WardrobeReDo/Models/Enums/ClothingSubcategory.swift` (lines 216-309)
- `WardrobeReDo/ViewModels/AddItemViewModel.swift::applyPrefill` (lines 1036-1045)

**A. Add shoe rescue mapping** (mirror accessory rescue):
```swift
static func shoeSubcategoryFromRawClass(_ raw: String) -> ClothingSubcategory? {
    switch raw.lowercased() {
    case "sneaker", "sneakers", "trainer", "running shoe": return .sneakers
    case "boot", "boots", "ankle boot": return .boots
    case "loafer", "loafers": return .loafers
    case "oxford", "derby", "brogue": return .oxfords
    case "sandal", "sandals": return .sandals
    case "heel", "heels", "pump": return .heels
    case "flat", "flats", "ballet flat": return .flats
    default: return nil
    }
}
```

**B. Expand accessory aliases:**
```swift
static func accessorySubcategoryFromRawClass(_ raw: String) -> ClothingSubcategory? {
    switch raw.lowercased() {
    case "glasses", "sunglasses", "eyewear", "shades", "spectacles": return .sunglasses
    case "belt", "waistband", "sash": return .belt
    // ... existing cases ...
    }
}
```

**C. Invert accessory logic in applyPrefill** so rescue runs FIRST for accessories:
```swift
if category == .accessory {
    if let rescue = ClothingSubcategory.accessorySubcategoryFromRawClass(modelClassRaw) {
        subcategory = rescue
    } else if let sub = proposal.predictedSubcategory, sub.category == category {
        subcategory = sub
    } else {
        subcategory = defaultSubcategory(for: category)
    }
} else if category == .shoe {
    if let rescue = ClothingSubcategory.shoeSubcategoryFromRawClass(modelClassRaw) {
        subcategory = rescue
    } else if let sub = proposal.predictedSubcategory, sub.category == category {
        subcategory = sub
    } else {
        subcategory = defaultSubcategory(for: category)
    }
} else {
    // existing logic
}
```

### WS-4: Texture rules firing for multi-pick

**Files:**
- `WardrobeReDo/ViewModels/AddItemViewModel.swift:997-1009` (legacy hard-reset path)
- `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift:356-375` (enrichment selection)
- `WardrobeReDo/Services/MultiGarmentTextureRules.swift` (rule definitions)

**Steps:**
1. Verify `FeatureFlags.isAttributeDetectionEnabled = true` in build 5
2. Remove or guard the legacy hard-reset path so multi-pick always uses the new `applyPrefill`
3. Add fallback rule: if `subcategory.fromML` is wrong (e.g. `.shorts` for jeans) but category is `.bottom`, look up rule by COLOR_FAMILY/BBOX_HEIGHT heuristic (deep blue + tall = jeans → denim)
4. Add logging in `applyAttributesAndRules` to surface which path fires

### WS-5: Color extraction overhaul

**File:** `WardrobeReDo/Services/ColorExtractionService.swift`

**Phase 1 (build 5.1) — quick wins:**
1. Raise alpha threshold from 128 → 200 (drop fringe pixels)
2. Add 1-px morphological erosion to mask before sampling (drop boundary)
3. Filter `percentage < 1.0` clusters (drop 0% display)

**Phase 2 (build 5.2) — perceptual clustering:**
4. Convert pixels to LAB color space before k-means
5. Use CIEDE2000 distance metric for clustering
6. Post-clustering merge: if two clusters' centroids ΔE < 8, merge

**Phase 3 (build 5.3) — display redesign:**
7. Reduce displayed swatches: 1 dominant + 2 accents (no percentages)
8. UI pattern: large dominant swatch + 2 small accents + "+N more" disclosure

**Code-ready:**
```swift
// New method to add to ColorExtractionService
private func mergeSimilarClusters(
    _ clusters: [Cluster], threshold deltaE: Double = 8.0
) -> [Cluster] {
    var merged = clusters
    var changed = true
    while changed {
        changed = false
        outer: for i in 0..<merged.count {
            for j in (i+1)..<merged.count {
                if ciede2000(merged[i].centerLAB, merged[j].centerLAB) < deltaE {
                    merged[i] = mergeWeightedAverage(merged[i], merged[j])
                    merged.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
    }
    return merged
}
```

### WS-6: Multi-pick UX redesign

(Pending K-design-critique-redesign.md)

Outline:
1. **Bulk-confirm screen** post-multi-pick — show all 6 detected items as a grid, ML-predicted attributes inline, "Confirm All" or "Edit details on N items" CTA
2. **Progressive disclosure** for the per-item form: show only Category + Subcategory + Colors + Save by default; "More details" disclosure for Texture/Fit/Season/Occasion/Notes
3. **Smart defaults** with confidence-based prompting: high-conf predictions silently saved, low-conf items surfaced as "Tap to confirm" cards
4. **Skip-and-edit-later** mode: "Skip details, save all 6" CTA puts items in wardrobe with ML predictions, surfaces a "Review N items" pill in wardrobe header for batch-edit later

### WS-7: Worn Outfits entity

**No schema change needed.** Use existing `wardrobe_items.source_photo_id` + `source_photo_path`.

**New view:** `WornOutfitsView`
- Group items WHERE `source_photo_id IS NOT NULL` BY `source_photo_id`
- For each group: source photo as the card image, member items as 4-up grid below
- "Worn on" date = MIN(created_at)
- Calendar view (later) — DateScrubber + outfits-by-date

**IA decision:** New tab? Sub-tab of Wardrobe? Or a row at top of Wardrobe?
- **Recommendation:** Tab order: Wardrobe / **Worn** / Outfits / Match / Profile (5 tabs).

### WS-8: Shoe redundancy v2

**File:** `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift::looksLikeShoeRedundancy`

**Current:** IoU-containment > 70%.
**Bug:** Real-world shoe pair detections don't overlap that much.

**New rule (multi-pronged):**
1. If both `.shoe` class AND centroids within 0.18 image-width AND y-midpoints within 0.10 → likely same physical shoe → keep higher-confidence
2. If 3+ shoe items detected → cap to 2 (one pair)
3. If wide-shot + close-up: detect by extreme aspect-ratio difference (close-up has w/h ≠ wide-shot's), prefer the wider-coverage one

### WS-9: Telemetry

**File:** `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift::makeProposal`

Add structured logging:
```swift
logger.info("multiGarment.proposal: rawClass=\(raw.modelClassRaw) confidence=\(raw.score) bbox=\(raw.boundingBox) finalCategory=\(category) finalSubcategory=\(subcategory)")
```

This lets us see in dogfood logs:
- What raw classes RFDETR is actually emitting
- Which mappings hit / miss
- Confidence distributions

### WS-10: Item card uniform white-bg

**File:** `WardrobeReDo/Views/Wardrobe/ItemCardView.swift:19-46`

**Replace:**
```swift
ZStack(alignment: .topTrailing) {
    KFImage(thumbnailURL)
        .resizable()
        .scaledToFill()
        .frame(minHeight: 160)
        .clipped()
}
.background(Theme.Colors.surface)
```

**With:**
```swift
ZStack(alignment: .topTrailing) {
    RoundedRectangle(cornerRadius: Theme.Radius.card)
        .fill(Color.white)
    KFImage(thumbnailURL)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 140, maxHeight: 140)
        .padding(12)
        .frame(height: 160, alignment: .center)
}
```

**Rationale:** Industry standard for fashion product cards — uniform white background, item centered with margin, scaled-to-fit (not fill).

## PR Sequencing

| PR | Branch | Workstreams | LOC | Migration |
|---|---|---|---|---|
| **#22** | `fix/build-4-blockers` | WS-1 (skip-mask Option C) + WS-2 + WS-3 | ~250 | None |
| **#23** | `fix/multi-pick-cutouts` | WS-1 (Option A real masks) + WS-4 + WS-8 | ~400 | None |
| **#24** | `fix/color-extraction-v2` | WS-5 (Phases 1+2) | ~300 | None |
| **#25** | `feat/uniform-cards` | WS-10 + WS-5 Phase 3 (color UI) | ~200 | None |
| **#26** | `feat/multi-pick-ux-v2` | WS-6 | ~600 | None |
| **#27** | `feat/worn-outfits` | WS-7 | ~300 | None |
| **#28** | `chore/capture-telemetry` | WS-9 | ~50 | None |

## Build Cadence

- **Build 5** (#22 + #23 + #24 + #28) — capture quality fixes + cutouts + color v2 + telemetry → re-dogfood
- **Build 6** (#25 + #26) — UI redesign (uniform cards + multi-pick UX) → user-test
- **Build 7** (#27) — Worn outfits → broader release

## Risk Controls

- Each PR is independently testable; PR ordering allows shipping #22 alone if #23 hits issues
- WS-1 Option C (skip mask) is reversible (set maskedData back to non-nil)
- WS-3 mapping changes are backward compatible (only ADD aliases, don't remove)
- WS-5 color overhaul behind a feature flag for first 24h post-deploy
- WS-7 (worn outfits) is purely additive — no impact on existing wardrobe view

## Out of Scope for Build 5

- RFDETR retraining (jeans→shorts misclassification): requires model work, not v1
- Fit prediction (deferred to v1.1 per ATTRIBUTE_TAXONOMY.md)
- LLM-generated outfit descriptions (build 6+)
- Calendar view of worn outfits (build 7+)
- iCloud sync (out of scope for v1)
