# Agent D — Save Path + Supabase Upload Flow (CRITICAL FINDINGS)

## Single-item flow upload (legacy, works correctly)
**Entry:** `AddItemViewModel.save(userId:)` when `currentProposal == nil`
**Upload:** `ImageService.upload(...)` lines 153-225

| Artifact | Source | Path Pattern | File Type |
|---|---|---|---|
| imagePath | `processed.originalData` | `{userId}/{itemId}/original.jpg` | JPEG 1200×1200 q80 |
| thumbnailPath | `processed.thumbnailData` | `{userId}/{itemId}/thumb.jpg` | JPEG 400×400 q80 |
| **maskedImagePath** | `processed.maskedData` (Vision/SAM2) | `{userId}/{itemId}/masked.png` | **PNG transparent-bg cutout** |

## Multi-pick flow upload (BROKEN)
**Entry:** `AddItemViewModel.startNextProposal()` line 910-983
**Per-proposal:** line 960 sets `maskedData: next.maskedImage.pngData()`

**THE BUG:** `MaskProposal.maskedImage` is NOT a transparent-bg cutout — it's a rectangular bounding-box CROP of the source photo.

Code: `MultiGarmentProposalService.cropped()` lines 933-946:
```swift
private static func cropped(_ image: UIImage, to normalizedBox: CGRect) -> UIImage? {
    guard let cg = image.cgImage else { return image }
    let rect = CGRect(
        x: normalizedBox.minX * w,
        y: normalizedBox.minY * h,
        width: normalizedBox.width * w,
        height: normalizedBox.height * h
    ).integral
    return UIImage(cgImage: cropped, ...)
}
```

This rect-crop becomes `MaskProposal.maskedImage` (line 786 of `makeProposal`), then uploaded as `masked.png` with the misleading name.

**Display consequence:** Wardrobe card with `displayPath = item.maskedImagePath ?? item.thumbnailPath` renders the rect-crop PNG → user sees source-photo backdrop on cards.

## Supabase production audit (build-4 multi-pick batch)

`source_photo_id = e711569e-6a5d-4851-a7ef-23405f716c65`, 6 items:
- ALL have `has_masked: true` (uploads work)
- ALL have `texture: null` (rules engine didn't fire)
- 5 of 6 have AI-prefilled subcategories that are wrong (sneakers→boots, sunglasses+belt→hat, jeans→shorts)
- Storage paths confirm: `{userId}/{itemId}/masked.png` — file IS there, just contains rect-crop content

## Worn-Outfit Feasibility — uses existing schema

`wardrobe_items.source_photo_id` (migration 00008) already groups items by capture session. `source_photo_path` retains the source JPEG. **No schema change required for v1.** Optionally add proper `worn_outfits` table (migration 00015) for cleaner data model + worn_at metadata.

## Files Needing Fix

| Issue | File | Lines |
|---|---|---|
| Multi-pick "mask" is rect crop (CORE BUG) | `Services/Extraction/MultiGarmentProposalService.swift` | 933-946 (cropped), 786 (makeProposal) |
| Mask data → maskedImagePath uses rect-crop | `ViewModels/AddItemViewModel.swift` | 960 |
| Worn-outfit entity (new) | new migration `00015_worn_outfits.sql` | - |

## Recommended Fix

**Option A (proper):** Use RFDETR-Seg's actual instance mask (`raw.mask` is plumbed through to `MaskProposal.mask` per Agent G — currently unused). Composite mask onto cropped source region → produce true transparent-bg PNG. ~50 LOC.

**Option B (quick):** Set `maskedData: nil` for multi-pick → ItemCardView falls back to thumbnailPath (source-photo crop). Still ugly but consistent with single-item flow placeholder behavior.

**Option C (best, longer):** New `display_image_path` column (migration 00014) with pre-rendered white-card composition (1024×1024 JPEG, item centered, 16pt padding). One-time render at upload. See web-research/G-ios-isolation-best-practices.md for code-ready snippets.
