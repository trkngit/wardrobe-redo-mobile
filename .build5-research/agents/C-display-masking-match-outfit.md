# Agent C — Display + Masking + Match + Outfit (BREAKTHROUGH FINDINGS)

## CRITICAL DISCOVERY: `MaskProposal.maskedImage` is misnamed

It's **NOT** a transparent-background masked cutout.
It's a **rectangular bounding-box crop** of the source photo.

`MultiGarmentProposalService.cropped()` (lines 933-946):
```swift
private static func cropped(_ image: UIImage, to normalizedBox: CGRect) -> UIImage? {
    guard let cg = image.cgImage else { return image }
    let rect = CGRect(
        x: normalizedBox.minX * w,  // bbox in pixel coords
        y: normalizedBox.minY * h,
        width: normalizedBox.width * w,
        height: normalizedBox.height * h
    ).integral
    return UIImage(cgImage: cropped, ...)
}
```

This rect-crop becomes `MaskProposal.maskedImage`, then uploaded as `masked.png`. **That's why IMG_2520 shows source-photo backdrop on the wardrobe cards** — the "masked" PNGs are just rectangular slices of the mirror selfie.

## What single-item flow does (correctly)
- `ImageService.processImage()` calls `ClothingExtractionService` (Vision + SAM2)
- Real instance segmentation produces transparent-bg cutout
- `maskedData = .pngData()` is a true cutout

## What multi-pick flow does (incorrectly)
- `RFDETRSegFashion` produces bbox + (presumably) seg mask
- `MultiGarmentProposalService.makeProposal` only USES the bbox
- `cropped()` returns rect crop, not the seg mask applied
- `next.maskedImage.pngData()` (line 960) writes the rect crop as "masked"

## Match tab piece selector — BUG CONFIRMED
**File:** `WardrobeReDo/ViewModels/MatchingViewModel.swift:170-176`
```swift
func loadThumbnails(for items: [WardrobeItem]) async {
    for item in items where thumbnailURLs[item.id] == nil {
        thumbnailURLs[item.id] = try? await imageService.signedURL(
            for: item.thumbnailPath  // BUG: hard-codes thumbnailPath
        )
    }
}
```
**Fix:** `for: ItemCardView.displayPath(for: item)`

## Outfit cards — BUG CONFIRMED (2 locations)
**File:** `WardrobeReDo/ViewModels/OutfitViewModel.swift:350, 359`
```swift
// Line 350
thumbnailURLs[item.id] = try? await imageService.signedURL(
    for: item.thumbnailPath  // BUG
)
// Line 359
let url = try? await imageService.signedURL(for: item.thumbnailPath)  // BUG
```
**Fix:** Same — use `ItemCardView.displayPath(for: item)`

## Outfit deduplication — designed-as-is
**File:** `WardrobeReDo/Services/OutfitGenerationService.swift:761-778`
- Dedup by `Set<UUID>` of item IDs
- Working as designed
- "Leather & Shadow" duplicate happens because the DB contains TWO shoe items (wide-shot + close-up of same physical shoe — both saved as `boots` due to Bug A and not collapsed by Bug F). Two outfits with different item-id-sets but visually identical.
- **Fix is upstream** (Bug F: shoe dedup in proposal generation), not in `deduplicateCandidates`.
- Optional dedup hardening: compare archetype + dominant-color fingerprint of items

## ItemCardView — sizing/centering issue
**File:** `WardrobeReDo/Views/Wardrobe/ItemCardView.swift:19-46`
- Current: `.scaledToFill().frame(minHeight: 160).clipped()` — image fills frame, edge-clipped
- No padding/centering — small items look tiny, large items look stretched
- Background is `Theme.Colors.surface` (likely dark gray)
- **For build 5:** white background + `.scaledToFit()` + `.frame(maxWidth: 140, maxHeight: 140).padding(12)` for breathing room

## Files Needing Fix

| Bug | File | Lines | Severity |
|---|---|---|---|
| Multi-pick "mask" is rect crop | `Services/Extraction/MultiGarmentProposalService.swift` | 933-946 (cropped) | CRITICAL |
| Mask data → maskedImagePath | `ViewModels/AddItemViewModel.swift` | 960 | CRITICAL |
| Match tab piece selector | `ViewModels/MatchingViewModel.swift` | 173 | HIGH |
| Outfit card thumbnails | `ViewModels/OutfitViewModel.swift` | 350, 359 | HIGH |
| Card centering / sizing | `Views/Wardrobe/ItemCardView.swift` | 19-46 | MEDIUM |
| Outfit dedup (upstream fix) | (Bug F upstream) | n/a | MEDIUM |

## Recommended Fix for Multi-Pick Masking

**Option 1 (minimal):** Set `maskedData: nil` in `startNextProposal` → ItemCardView falls back to thumbnailPath. Wardrobe cards show source-photo thumbnail instead of bbox crop. Not great visual but consistent.

**Option 2 (proper):** Use RFDETR-Seg-Fashion's actual instance mask. Render the segmentation mask onto the cropped region, save as transparent-bg PNG. Requires understanding what `RFDETRSegFashion` outputs (does it have a per-instance mask?).

**Option 3 (Vision fallback):** After RFDETR produces bboxes, run `VNGenerateForegroundInstanceMaskRequest` on each bbox region to get a clean per-garment mask. iOS 17+ only, slow per-instance.

**Build 5 plan: Option 2 (proper) with Option 3 fallback** for items where RFDETR's mask is poor quality.

## Worn-Outfit Feasibility — NO SCHEMA CHANGE NEEDED
- `wardrobe_items.source_photo_id` (migration 00008) already groups items
- `source_photo_path` already retains the full source JPEG
- New "Worn Outfits" view: `SELECT DISTINCT source_photo_id, source_photo_path, MIN(created_at) FROM wardrobe_items WHERE source_photo_id IS NOT NULL GROUP BY source_photo_id, source_photo_path`
- Each session shows: source photo + member items below + "worn on" date
