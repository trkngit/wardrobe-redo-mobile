# Agent E — Match + Outfit Dedup (more views found)

## displayPath bug surface — wider than thought

Beyond the 2 viewmodels Agent C found:
- `Views/Matching/MatchingView.swift:89` — heroItemCell (driven by MatchingViewModel)
- `Views/Outfits/MatchResultCard.swift:72` — itemThumbnail (also driven by MatchingViewModel)
- `Views/Outfits/OutfitCardView.swift:87` — itemThumbnail (driven by OutfitViewModel)
- `Views/Outfits/OutfitDetailView.swift:107` — itemCard (driven by OutfitViewModel)

All four views read from `viewModel.thumbnailURLs[item.id]`. The bug is in the 2 viewmodels:

### MatchingViewModel.swift:173
```swift
thumbnailURLs[item.id] = try? await imageService.signedURL(
    for: item.thumbnailPath  // BUG
)
```

### OutfitViewModel.swift:350, 359
```swift
// loadThumbnails():
thumbnailURLs[item.id] = try? await imageService.signedURL(
    for: item.thumbnailPath  // BUG
)
// thumbnailURL(for:):
let url = try? await imageService.signedURL(for: item.thumbnailPath)  // BUG
```

### Reference (correct pattern in WardrobeViewModel.swift:226):
```swift
try? await imageService.signedURL(for: ItemCardView.displayPath(for: item))
```

## Outfit Dedup — Working As Designed

`Services/OutfitGenerationService.swift:761-778` dedupes by `Set<UUID>` of item IDs. If two outfits share IDs exactly → one survives. Working correctly.

The "Leather & Shadow EDGY 80" duplicate in IMG_2521:
- Editorial name + archetype + score are deterministic per archetype family
- If two outfits have DIFFERENT item-id sets, they pass dedup as different, and will appear with the same NAME because the name is archetype-driven
- "Visual duplication" is consequence of multiple items in DB looking the same (e.g., wide-shot boot + close-up boot both as `subcategory: boots`)

**Upstream fix:** prevent RFDETR from producing dup items (Bug F). Then dedup works visually too.

**Optional dedup hardening:** key on `(archetype.id, items.sorted by id)` — kills cases where same archetype produces semantically duplicate outfits.

## Match Tab Piece Labels
- Labels come from `item.subcategory.displayName` (line 113)
- "Hat" twice = sunglasses + belt miscategorized (Bug B/C)
- "Boots" twice = wide-shot + close-up shoe (Bug A + F)

These are SYMPTOMS of upstream bugs, not their own bugs.

## Build 5 Fix List for This Lane

| # | File | Line | Change |
|---|---|---|---|
| 1 | `MatchingViewModel.swift` | 173 | `for: item.thumbnailPath` → `for: ItemCardView.displayPath(for: item)` |
| 2 | `OutfitViewModel.swift` | 350 | Same |
| 3 | `OutfitViewModel.swift` | 359 | Same |
| 4 | (no new view changes needed — all 4 views consume the cache) | — | — |
