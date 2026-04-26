# Agent B — Multi-Garment + Subcategory + Texture Pipeline

## Bug A — Sneakers → "Boots"

**Root cause:** `ClothingSubcategory.fromFashionpediaClass` (lines 216-283) DOES NOT include "sneaker" in its switch. Fashionpedia class list (`MultiGarmentProposalService.swift:148-158`) only has generic `"shoe"`, `"boot"`, `"sandal"`. When model emits `"shoe"`, mapping returns `nil`, falls through to `defaultSubcategory(for: .shoe)` = `.sneakers` (correct default!). BUT if model emits `"boot"`, it explicitly maps to `.boots` and locks misclassification in.

**Deeper:** Fashionpedia training data has no fine-grained shoe types. RFDETR can't distinguish sneaker vs boot vs oxford. **Footwear needs a secondary refinement layer (or shoe-type rescue mapping).**

**Fix:** Add `static func shoeSubcategoryFromRawClass(_ raw: String) -> ClothingSubcategory?` mirror of accessory rescue. Patterns: "sneaker" → .sneakers, "boot" → .boots, "loafer" → .loafers, "oxford" → .oxfords. BUT: if model only emits generic "shoe"/"boot", rescue won't help — need secondary classifier.

## Bug B — Sunglasses → "Hat"

**Root cause:** PR #19's accessory rescue branch in `applyPrefill` is bypassed when `proposal.predictedSubcategory != nil`. Logic:
```swift
if let sub = proposal.predictedSubcategory, sub.category == category {
    subcategory = sub  // ← .hat from upstream wins here
} else if category == .accessory, let rescue = ... {
    subcategory = rescue  // ← never reached
}
```

**Likely upstream:** Either (a) RFDETR emits a class like `"eyewear"` / `"shades"` not in mapping → `predictedSubcategory = nil` → falls to `defaultSubcategory(for: .accessory)` = `.hat`. OR (b) mapping returns `.sunglasses` correctly (line 251) and the bug is elsewhere.

**Most likely:** The model emits an unrecognized raw class. The CURRENT mapping handles "glasses"/"sunglasses" exactly. Need to expand aliases.

**Fix:** Expand `fromFashionpediaClass` AND `accessorySubcategoryFromRawClass` with aliases:
```swift
case "eyewear", "shades", "spectacles", "glasses", "sunglasses": return .sunglasses
case "belt", "waistband", "sash": return .belt
```

**ALSO:** Logic order is wrong. The accessory rescue should run BEFORE accepting `predictedSubcategory == .hat` for accessories — because `.hat` is the default when mapping fails. Better:
```swift
if category == .accessory {
    // Try raw-class rescue FIRST for accessories
    if let rescue = ClothingSubcategory.accessorySubcategoryFromRawClass(modelClassRaw) {
        subcategory = rescue
    } else if let sub = proposal.predictedSubcategory, sub.category == category {
        subcategory = sub
    } else {
        subcategory = defaultSubcategory(for: category)
    }
} else { /* existing logic */ }
```

## Bug C — Belt → "Hat"

Same as B. Fix: expand "belt" alias to include "waistband", "sash". Apply the inverted accessory logic.

## Bug D — Jeans → "Shorts"

**Root cause:** `fromFashionpediaClass("pants")` returns `nil` (documented as ambiguous), falls back to `defaultSubcategory(.bottom) = .jeans`. **If form shows .shorts, model is emitting "shorts" for full-length jeans.**

**Fix:** Cannot fix in mapping alone. Options:
1. RFDETR retraining (out of scope)
2. Secondary length classifier on masked image (analyze bounding box height vs body proportions)
3. Heuristic: if bbox height > 0.4 of frame, override "shorts" → "pants"

## Bug E — Texture Not Pre-Selected

**Root cause investigation:**
- Texture pre-fill happens at `MultiGarmentProposalService.swift:860-862` (ML path) and 863-868 (rules fallback)
- For jeans: `RulesTable.texture(.jeans)` returns `.denim` confidence 0.85
- Unit tests (`MultiGarmentTextureRulesTests.swift:49-64`) PASS

**Why it fails in real captures:**
- `FeatureFlags.isAttributeDetectionEnabled` may be **off** at AddItemViewModel.swift:998 — triggers legacy hard-reset INSTEAD of `applyPrefill`
- Or `attributeClassifier` is `nil` and exceptions silently fall back to `enrichedWithRulesOnly` (line 374) which calls `applyAttributesAndRules(prediction:.empty)` (line 827) — should still hit rules engine
- Or `proposal.predictedSubcategory` is `nil` for jeans (because "pants" → nil), falls back to category default

**Fix:** Verify `FeatureFlags.isAttributeDetectionEnabled = true`. Remove legacy hard-reset path. Add logging to `applyAttributesAndRules` to surface the path taken.

## Bug F — Shoe Redundancy Collapse Didn't Fire

**Current heuristic** (`MultiGarmentProposalService.swift:682-689`):
```swift
let intersection = a.intersection(b).area
let smaller = min(a.area, b.area)
return intersection / smaller > 0.7
```

**Why it fails on real photos:** Wide-shot at (x=0.2-0.5, y=0.4-0.8) and close-up at (x=0.1-0.3, y=0.9-1.0) — close-up of LACES is at top-center while wide-shot is mid-left. They don't overlap by 70% in real-world captures. Synthetic test data was pristine.

**Fix options:**
1. Lower threshold: 0.7 → 0.5
2. Add proximity heuristic: if both `.shoe` class AND centroids within 0.15 image-width AND similar aspect ratios, merge
3. Add "duplicate shoe-class" cap: at most N shoe items per source photo (configurable)

## Bug G — Fit Not Pre-Selected

**Root cause:** Fit is **purely ML-driven** — no rules fallback in v1. Fashionpedia v2 doesn't carry fit attributes (see `ATTRIBUTE_TAXONOMY.md` Phase 0). Classifier is not trained for fit.

**Fix:** Defer to v1.1. No v1 fix possible without retraining.

## Files-To-Modify Summary

| Bug | File | Lines |
|---|---|---|
| A | `Models/Enums/ClothingSubcategory.swift` | 216-283 (add shoe rescue), new helper |
| B,C | `Models/Enums/ClothingSubcategory.swift` | 250-251, 260, 295-309 (expand aliases) |
| B,C | `ViewModels/AddItemViewModel.swift` | 1036-1045 (invert accessory logic) |
| D | `MultiGarmentProposalService.swift` | new — secondary length classifier |
| E | `ViewModels/AddItemViewModel.swift` | 997-1009 (verify flag, remove legacy reset) |
| E | `MultiGarmentProposalService.swift` | 356-375 (logging) |
| F | `MultiGarmentProposalService.swift` | 682-689 (lower threshold OR add proximity) |
| G | DEFERRED to v1.1 | n/a |

## RFDETR Class List (raw labels)

From `MultiGarmentProposalService.swift:148-158`:
- `top`, `t-shirt`, `shirt`, `blouse`, `polo`, `sweater`, `cardigan`, `jacket`, `blazer`, `coat`, `dress`, `pants`, `jeans`, `shorts`, `skirt`, `shoe`, `boot`, `sandal`, `sneakers`, `hat`, `bag`, `belt`, `glasses`, `sunglasses`, `tie`, `scarf`, `gloves`, `socks`

(Verify this is exhaustive vs. actual RFDETR-Seg-Fashion training labels.)
