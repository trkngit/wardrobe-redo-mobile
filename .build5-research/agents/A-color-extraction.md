# Agent A — Color Extraction Pipeline Deep Dive

## Algorithm
- **k-means++** with smart init, 5 clusters hard-coded (`maxColors: Int = 5`)
- **RGB color space**, squared Euclidean distance — NOT perceptually uniform
- 50×50 downsampling, max 20 iterations, convergence threshold 0.001
- File: `WardrobeReDo/Services/ColorExtractionService.swift`

## Pixel Sampling (lines 53–93)
- Skips alpha < 128 → already respects mask transparency
- Un-premultiplies pixels before clustering
- `premultipliedLast` CGContext for predictable byte order

## CRITICAL FINDINGS

### No post-clustering merging
Returns ALL 5 clusters regardless of similarity. For single-color blue jeans with wrinkles, k-means picks 5 clusters in same hue range. **No CIEDE2000, no Delta-E, no hue-distance merge.**

### No min-percentage filter
Tiny clusters (e.g. 0.4%) round to 0% but still display.

### Soft-edge mask leakage
Vision framework masks have anti-aliased edges (alpha 100–200). Color extractor's threshold of `alpha < 128` lets fringe pixels through → **skin tone leakage on sunglasses palette**.

## Models
- `ExtractedColor` (in-flight): hex, hue, saturation, lightness, percentage, family, isNeutral
- `ColorProfile` (persisted): same fields, snake_case CodingKeys, JSONB on `wardrobe_items.dominant_colors`

## Consumers
1. **Add Item form**: `Views/Wardrobe/AddItemView.swift:441` — `ColorSwatchView(colors: viewModel.extractedColors, size: 28, showPercentage: true)`
2. **Item Detail**: `Views/Wardrobe/ItemDetailView.swift:212` — `ColorSwatchDetailView(colors: item.dominantColors)`
3. **Item Card**: `Views/Wardrobe/ItemCardView.swift:51` — `prefix(3)` swatches
4. **ColorHarmonyScorer**: `Services/StyleEngine/ColorHarmonyScorer.swift` — sees 5 "colors" when actually 1 (broken outfit scoring)

## Call Sites
1. `ImageService.swift:107` — `colorExtractor.extractColors(from: extraction.maskedImage)` (single-item)
2. `AddItemViewModel.swift:952` — per-proposal multi-pick (PR #19 A2)
3. `ImageService.swift:246` — after mask touch-up

## Mask Output
- `VisionForegroundExtractor.swift:131-155` produces transparent-bg PNG via `CIBlendWithMask`
- **Vision masks are SOFT-EDGED** (anti-aliased). Fringe pixels at boundaries have intermediate alpha → leakage.

## Test Coverage Gaps
- ❌ No integration test for `extractColors`
- ❌ No assertion on cluster count
- ❌ No similar-cluster merging test
- ❌ No min-percentage filter test
- ❌ No non-uniform garment fixture

## Change Points

| # | Location | Change |
|---|---|---|
| 1 | `ColorExtractionService.swift:95-119` | Insert post-clustering merge step |
| 2 | Same file, new func | Add LAB color space + CIEDE2000 distance |
| 3 | Lines 102-118 | Filter `percentage < 1.0` before mapping |
| 4 | Lines 70-87 | Raise alpha threshold to ≥192 to exclude fringe |
| 5 | Line 179 | Long-term: cluster in LAB space |

## Root Cause Summary

| Issue | Cause | Severity |
|---|---|---|
| 5 nearly-identical blues | No cluster merging; lightness variation from wrinkles produces 5 close clusters | HIGH |
| Skin tone in sunglasses palette | Soft-edge mask + fringe pixels with α 100-200 | HIGH |
| 0% cluster shown | No min-% filter | MEDIUM |
| Outfit scoring sees 5 colors when 1 | No merging upstream → ColorHarmonyScorer overcounts unique families | HIGH |
