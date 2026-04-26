# Build 5 — Capture-Pipeline + Display Rework

> **Status:** Plan, ready for implementation
> **Author:** Built from build-4 dogfood (10 screenshots) + 9 parallel research agents + Supabase production audit
> **Created:** 2026-04-26
> **Implementer:** Opus 4.7 (1M context)
> **Research workspace:** `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/.build5-research/` — see `INDEX.md` first

## How to read this plan (for context-loss resilience)

Each PR section in this plan is **self-contained**. You can pick up at any PR after a context reset by reading just:
1. This file's "Quick context" section
2. The specific PR section you're working on
3. The cross-referenced research files for deep dives

**If context is tight,** read PR sections lazily — only `Read` the research file when the PR section says "deep dive: see research/X.md".

## Quick context (read first if resuming cold)

**The problem:** TestFlight build 4 shipped today. User dogfooded a 6-item multi-pick from a mirror selfie. Result: 6 wrong predictions accepted (sneakers→Boots, sunglasses+belt→Hat, jeans→Shorts, layered tops→single T-Shirt), texture pre-fill failed on every item, color palettes show 5 nearly-identical shades + skin-tone leak + a "0%" cluster, wardrobe grid renders multi-pick items with the source-photo backdrop, Match tab + Outfit cards have the same backdrop bug. Fix: capture-pipeline overhaul + display normalization across all 4 view surfaces + UX rework.

**Source artifacts:**
- Screenshots: `/Users/tarkansurav/Downloads/After build 4/IMG_2512..2521.PNG`
- Production Supabase data: `xavxlsutdcvllbvmxoma`, `wardrobe_items` table, `source_photo_id = e711569e-6a5d-4851-a7ef-23405f716c65`
- Research workspace index: `.build5-research/INDEX.md`

**Build 5 = 7 PRs** (#22 through #28). Suggested ship cadence: TestFlight build 5 = #22+#23+#24+#28; build 6 = #25+#26; build 7 = #27.

---

## Critical findings driving this plan

### 1. The multi-pick "masked image" is a rectangular bbox crop, not a real cutout
**Source:** `agents/C-display-masking-match-outfit.md`, `agents/D-save-path-supabase.md`, `web-research/G-ios-isolation-best-practices.md`

`MultiGarmentProposalService.cropped()` (lines 933-946) returns `UIImage(cgImage: cropped, ...)` — a rectangular slice of the source photo. This becomes `MaskProposal.maskedImage`, gets uploaded as `masked.png`. **The wardrobe grid + Match tab + Outfit cards then show this rect-crop, which looks like the source-photo backdrop.**

The RFDETR-Seg model **does** produce per-instance segmentation masks (`raw.mask`), and they're plumbed through to `MaskProposal.mask` — but the code never composites them onto the source. Single-item flow uses Vision+SAM2 which produces real cutouts; multi-pick has never produced real cutouts.

### 2. RFDETR-Seg-Fashion class list has been mis-modeled in our mapping
**Source:** `web-research/J-rfdetr-fashionpedia-classes.md`

The model emits Fashionpedia class names with **underscores** for combo classes:
- `shirt_blouse` (not `shirt`)
- `top_t-shirt_sweatshirt` (not `top` or `t-shirt`)
- `bag_wallet` (not `bag` or `wallet`)
- `glasses` (not `sunglasses`)

Our `ClothingSubcategory.fromFashionpediaClass` switch has cases for `"sunglasses"`, `"cap"`, `"trousers"`, `"jeans"`, `"gown"`, `"bag"`, `"wallet"`, `"purse"`, `"sweatshirt"`, `"top"`, `"shirt"`, `"t-shirt"` — **all dead code.** None will ever fire because the model doesn't emit those tokens.

Worse: Fashionpedia has **no sneaker, jeans, or chinos classes at all** — these are attributes (`nickname:jeans`, attribute id 36), not categories. The 33-class trained model can only emit `pants`, `shorts`, `skirt`, `shoe`, `boot`, `sandal`. There's no taxonomy fix for sneaker-vs-boot or jeans-vs-shorts; need either a secondary classifier or better default selection.

### 3. Subcategory rescue logic in `applyPrefill` is inverted for accessories
**Source:** `agents/B-multigarment-subcategory-texture.md`

```swift
// Current logic in AddItemViewModel.applyPrefill (lines 1036-1045):
if let sub = proposal.predictedSubcategory, sub.category == category {
    subcategory = sub  // ← .hat default from upstream wins
} else if category == .accessory, let rescue = ... {
    subcategory = rescue  // ← never reached
}
```

For accessories, the predicted subcategory often defaults to `.hat` (the most common accessory class). The first branch unconditionally accepts it, bypassing the rescue. Need to invert order for accessories specifically.

### 4. Color extraction picks shadow regions as dominant
**Source:** `agents/A-color-extraction.md`, `web-research/F-color-extraction-soa.md`

Pipeline: 50×50 downsample → k-means in RGB → sort by cluster size → return top 5. Real-world garment photos have substantial shadow regions; k-means clusters them as #1 dominant. This is why "blue jeans" first color is `#332E2C gray hue 20°` — the belt-shadow cluster.

Vision framework masks have soft anti-aliased edges (alpha 100-200 at boundaries). Color extractor's `alpha < 128` threshold lets fringe pixels through → skin-tone leakage on the sunglasses palette.

No post-clustering merge → "5 shades of blue" for a single-color garment with wrinkles. No min-percentage filter → "0%" cluster slips through display.

### 5. Display-layer bug surface wider than PR #20 fixed
**Source:** `agents/E-match-outfit-dedup.md`

PR #20 added `ItemCardView.displayPath` (maskedImagePath ?? thumbnailPath) for the wardrobe grid. **But the same fallback wasn't applied to:**
- `MatchingViewModel.swift:173` — Match tab piece selector
- `OutfitViewModel.swift:350` — Outfit cards (loadThumbnails)
- `OutfitViewModel.swift:359` — Outfit cards (thumbnailURL fallback)

Three line changes. Affects 4 views (MatchingView heroItemCell, MatchResultCard itemThumbnail, OutfitCardView itemThumbnail, OutfitDetailView itemCard).

---

## PR Sequence (7 PRs, each independently testable)

### PR #22 — Display normalization (P0, ~150 LOC)
**Branch:** `fix/build-4-display-bugs`
**Severity:** BLOCKER — fixes visible regression
**Migration:** None
**Dependencies:** None

**What it does:** Apply PR #20's `displayPath` fallback to the 3 missing call sites + introduce a unified `ItemThumbnailView` component to prevent future regressions.

**Files:**

| File | Lines | Change |
|---|---|---|
| `WardrobeReDo/ViewModels/MatchingViewModel.swift` | 173 | `for: item.thumbnailPath` → `for: ItemCardView.displayPath(for: item)` |
| `WardrobeReDo/ViewModels/OutfitViewModel.swift` | 350 | Same |
| `WardrobeReDo/ViewModels/OutfitViewModel.swift` | 359 | Same |
| `WardrobeReDo/Views/Components/ItemThumbnailView.swift` (new) | — | Unified component: `(item, size: .small/.medium/.large)` resolves displayPath internally. Used by all 4 call sites. |

**Tests:**
- `WardrobeReDoTests/Views/ItemThumbnailViewTests.swift` (new) — pin maskedImagePath wins / thumbnailPath fallback
- Existing tests must continue to pass

**Verification:**
- Match tab piece selector shows cropped cutouts for items that have `maskedImagePath` (existing items including build-4 multi-pick still show rect-crop until PR #23 lands real cutouts)
- Outfit cards same
- No new build warnings

**Deep dive:** `agents/E-match-outfit-dedup.md`, `agents/C-display-masking-match-outfit.md`

---

### PR #23 — Real per-garment masking + shoe redundancy v2 (P0, ~400 LOC)
**Branch:** `fix/multi-pick-real-cutouts`
**Severity:** BLOCKER — root cause of source-photo backdrop
**Migration:** Optional — `00014_display_image_path.sql` (additive, nullable column)
**Dependencies:** PR #22 (display fixes) — not strict, but easier to verify visually

**What it does:** Replace `MultiGarmentProposalService.cropped()` with `compositeMaskedItem()` that uses `raw.mask` (RFDETR-Seg's per-instance mask) to produce a true transparent-background cutout. Also fix shoe redundancy v2 (proximity-based instead of IoU-based).

**Files:**

| File | Lines | Change |
|---|---|---|
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | 933-946 (cropped) | Replace with `compositeMaskedItem(sourceImage: UIImage, mask: CVPixelBuffer, bbox: CGRect) -> UIImage?`. Composite mask onto cropped region, return transparent-bg PNG. Code-ready in `web-research/G-ios-isolation-best-practices.md`. |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | 776 (makeProposal) | Pass `raw.mask` to the new `compositeMaskedItem`. |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | 682-689 (looksLikeShoeRedundancy) | Replace 70% IoU containment with proximity-based merge: same `.shoe` class AND centroids within 0.18 image-width AND y-midpoints within 0.10 → keep higher-confidence. Cap at 2 shoe items per source photo. |
| `WardrobeReDo/Services/Extraction/MaskCleaner.swift` (new) | — | 3-step CIFilter cleanup: `CIColorThreshold` (binary 0/1) → `CIMorphologyMinimum radius=1` (1-px erode) → `CIGaussianBlur radius=0.5` (sub-pixel anti-alias). Used to clean RFDETR mask edges. |

**Tests:**
- `WardrobeReDoTests/Services/Extraction/MultiGarmentProposalServiceMaskingTests.swift` (new) — round-trip a synthetic source + mask through `compositeMaskedItem`, assert output PNG has alpha=0 outside mask + alpha=255 inside.
- `WardrobeReDoTests/Services/Extraction/MultiGarmentShoeRedundancyTests.swift` — extend with proximity-based test cases: wide-shot + close-up at same y collapse; two shoes far apart kept; 3-shoe cap.

**Verification:**
- Multi-pick a photo of yourself → wardrobe cards show transparent-bg cutouts on white surface
- Compare to pre-build-3 single-item saves (visual parity)
- Existing 700-test suite passes

**Deep dive:** `agents/C-display-masking-match-outfit.md`, `agents/D-save-path-supabase.md`, `web-research/G-ios-isolation-best-practices.md` sections 1-3

---

### PR #24 — Subcategory mapping fixes (P0, ~250 LOC)
**Branch:** `fix/subcategory-mapping`
**Severity:** BLOCKER — every multi-pick item gets wrong subcategory
**Migration:** None
**Dependencies:** None

**What it does:** Fix the dead-code aliases in `fromFashionpediaClass`, add accessory rescue inversion, add shoe-default sanity check.

**Files:**

| File | Lines | Change |
|---|---|---|
| `WardrobeReDo/Models/Enums/ClothingSubcategory.swift` | 216-283 (`fromFashionpediaClass`) | Update cases to match actual model output. **The model emits underscored combo classes** (`shirt_blouse`, `top_t-shirt_sweatshirt`, `bag_wallet`). Add cases for these. Drop dead-code cases for `"sunglasses"`, `"trousers"`, `"jeans"`, `"cap"`, `"gown"`, `"bag"`, `"wallet"`, `"purse"`, `"top"`, `"sweatshirt"`, `"t-shirt"`, `"shirt"`. Keep `"glasses"` → `.sunglasses`. Map `top_t-shirt_sweatshirt` → `.tshirt`, `shirt_blouse` → `.buttonDown`, `bag_wallet` → `.bag`. |
| `WardrobeReDo/Models/Enums/ClothingSubcategory.swift` | 295-309 (`accessorySubcategoryFromRawClass`) | Match actual model classes. Drop dead-code aliases. |
| `WardrobeReDo/Models/Enums/ClothingSubcategory.swift` | new | Add `static func shoeSubcategoryFromRawClass(_ raw: String) -> ClothingSubcategory?`. The model emits only `shoe`, `boot`, `sandal` — no sneaker class. Map: `"shoe"` → return `nil` (let caller use `.sneakers` default), `"boot"` → `.boots`, `"sandal"` → `.sandals`. |
| `WardrobeReDo/ViewModels/AddItemViewModel.swift` | 1036-1045 (applyPrefill) | **Invert the logic for accessories AND shoes:** rescue runs FIRST, then predictedSubcategory fallback, then default. See snippet below. |

**Logic inversion snippet:**
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
        subcategory = defaultSubcategory(for: category)  // .sneakers (correct default)
    }
} else {
    if let sub = proposal.predictedSubcategory, sub.category == category {
        subcategory = sub
        snapshot["subcategory"] = sub.rawValue
    } else {
        subcategory = defaultSubcategory(for: category)
    }
}
```

**Tests:**
- `WardrobeReDoTests/Models/Enums/ClothingSubcategoryFashionpediaMappingTests.swift` (new) — assert every model-emitted class string maps to expected subcategory. Use the authoritative class list from `J-rfdetr-fashionpedia-classes.md` section "Authoritative class table" as test parameters.
- `WardrobeReDoTests/ViewModels/AddItemViewModelAccessoryRescueTests.swift` (new) — assert sunglasses (`glasses` raw class) → `.sunglasses`, belt → `.belt`, regardless of `predictedSubcategory` value.

**Verification:**
- Multi-pick a sunglasses + belt photo → form pre-fills correctly.
- No regression in existing prefill tests.

**Deep dive:** `web-research/J-rfdetr-fashionpedia-classes.md` (CRITICAL — has the full class table), `agents/B-multigarment-subcategory-texture.md`

---

### PR #25 — Texture rules firing for multi-pick (P0, ~80 LOC)
**Branch:** `fix/texture-rules-multipick`
**Severity:** BLOCKER — texture not pre-filled on any multi-pick item
**Migration:** None
**Dependencies:** PR #24 (correct subcategory needed for rules to fire)

**What it does:** Make sure `MultiGarmentTextureRules.deriveTexture(category:subcategory:)` fires for multi-pick items.

**Files:**

| File | Lines | Change |
|---|---|---|
| `WardrobeReDo/ViewModels/AddItemViewModel.swift` | 997-1009 | Verify `FeatureFlags.isAttributeDetectionEnabled = true` in build 5 build configuration. Remove or guard the legacy hard-reset path. |
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` | 356-375 | Add structured logging: `logger.info("multiGarment.enrichment: path=\(pathTaken) category=\(category) subcategory=\(subcategory) texture=\(texture)")` to surface where rules engine takes which branch. |
| `WardrobeReDo/Services/MultiGarmentTextureRules.swift` | various | Add fallback rule: if `subcategory == nil` (pants→nil from Fashionpedia mapping), look up by category + bbox aspect ratio. Tall+narrow + .bottom → likely jeans → .denim. |

**Tests:**
- Existing `MultiGarmentTextureRulesTests.swift` should still pass.
- Add: `WardrobeReDoTests/Services/MultiGarmentTextureRulesIntegrationTests.swift` — feed a real multi-pick proposal with `predictedSubcategory: .shorts` (model error for full-length jeans) AND bbox height > 0.4 → fallback rule overrides to `.denim`.

**Verification:**
- Multi-pick a denim jeans → form's Texture chip shows `Denim` selected.

**Deep dive:** `agents/B-multigarment-subcategory-texture.md` Bug E section

---

### PR #26 — Color extraction overhaul (P0, ~350 LOC)
**Branch:** `feat/color-extraction-v2`
**Severity:** BLOCKER — palette quality is unusable
**Migration:** None
**Dependencies:** None (independent)

**What it does:** Replace RGB k-means with CIELAB k-means + perceptual cluster merging + skin-tone suppression + min-% filter + alpha-threshold raise.

**Files:**

| File | Change |
|---|---|
| `WardrobeReDo/Services/ColorExtractionService.swift` | Phase 1: alpha threshold 128 → 200. Add 1-px erode of mask before sampling. Filter `percentage < 1.0` clusters. Phase 2: convert pixels to CIELAB before clustering. Phase 3: post-clustering merge using CIEDE2000 (ΔE ≤ 8 → merge weighted). Phase 4: skin-tone exclusion (Lab a* ∈ [10, 25], b* ∈ [10, 30], L ∈ [40, 85]). |
| `WardrobeReDo/Services/ColorExtractionService.swift` (new helpers) | `func srgbToLab(_:) -> (L: Double, a: Double, b: Double)`, `func ciede2000(_ a: LabColor, _ b: LabColor) -> Double`, `func mergeSimilarClusters(_ clusters: [Cluster], threshold: Double) -> [Cluster]`, `func isSkinTone(_ lab: LabColor) -> Bool`. |

**The "5 shades of blue" fix mechanics:**
1. Convert all pixel samples to CIELAB
2. k-means in CIELAB (not RGB)
3. After clustering, merge any two clusters whose centroids ΔE76 ≤ 5.0 (perceptually indistinguishable)
4. Drop any cluster matching skin-tone gamut
5. Drop any cluster with % < 3%
6. Display top 1-3 remaining clusters

**Tests:**
- Extend existing `ColorExtractionServiceTests.swift` with:
  - `mergesSimilarClustersInLab` — synthetic 5 shades of blue → 1 cluster after merge
  - `dropsSkinToneCluster` — synthetic image with skin + blue → only blue remains
  - `dropsBelowOnePercentCluster` — synthetic 99% blue + 0.5% red → only blue
  - `usesAlphaThreshold200` — fringe pixels with alpha 150 are excluded
- Snapshot test on a real garment image fixture (denim jeans) → output is one cluster, family `blue`, lightness > 0.3.

**Verification:**
- Multi-pick a denim jeans + the form shows ONE blue swatch (`indigo` or similar named family) at high lightness.
- Sunglasses palette no longer includes skin tone.
- No `0%` cluster.

**Deep dive:** `web-research/F-color-extraction-soa.md` (664 lines, includes Swift code for sRGB→Lab + CIEDE2000 + cluster merging), `agents/A-color-extraction.md`

---

### PR #27 — Item card uniform white background + scaledToFit (P0, ~150 LOC)
**Branch:** `feat/uniform-item-cards`
**Severity:** HIGH — biggest visual quality lift
**Migration:** None
**Dependencies:** PR #22 (unified ItemThumbnailView)

**What it does:** Standardize the item card visual language across all 4 surfaces (Wardrobe / Match / Outfit cards / Detail view hero). White background, 1:1 square, scaledToFit, 16pt padding. Replace the 5-swatch color UI with `EditorialColorView` (single hero color + name + "+N accents" expander).

**Files:**

| File | Change |
|---|---|
| `WardrobeReDo/Views/Components/ItemThumbnailView.swift` (from PR #22) | Implement white background, aspectRatio(1, .fit), scaledToFit, padding(16). Three sizes (.small 44pt, .medium 160pt, .large full-width). |
| `WardrobeReDo/Views/Components/EditorialColorView.swift` (new) | Single 56×56 color circle + family name (e.g., "Indigo") + caption + "+N accents" expander. Replaces every site that uses `ColorSwatchView(showPercentage: true)`. |
| `WardrobeReDo/Services/ColorNamer.swift` (new) | Lab → English color name lookup table (~100 lines). Map color family + lightness → "Indigo" / "Charcoal" / "Cream" / etc. |
| `WardrobeReDo/Views/Wardrobe/AddItemView.swift` | line 441-449 — replace `ColorSwatchView` with `EditorialColorView`. |
| `WardrobeReDo/Views/Wardrobe/ItemDetailView.swift` | line 212-215 — same. |
| `WardrobeReDo/Views/Wardrobe/ItemCardView.swift` | Remove `prefix(3)` color circles. Move single-hero color into `EditorialColorView` overlay if at all. |

**Card spec (per `K-design-critique-redesign.md` §3):**
- **Background:** Pure white (`#FFFFFF`) light mode; `#1C1C1E` dark mode
- **Aspect ratio:** 1:1 square — no exceptions
- **Image rendering:** `.scaledToFit().padding(16)` — sunglasses and t-shirts both fill ~70% of card edge
- **Cutout source:** `maskedImagePath` only. No fallback to source photo. (Legacy items get backfilled in PR #23.)
- **Foreground content:** subcategory chip (top-left), single hero color dot (bottom-left, 12pt), wear count (bottom-right)

**Tests:**
- Snapshot tests on `ItemThumbnailView` for various items (small/medium/large) — white bg, item centered, padding visible.
- `WardrobeReDoTests/Services/ColorNamerTests.swift` — assert (#3366CC, blue family) → "Indigo" or similar.

**Verification:**
- Wardrobe grid: every card shows item centered on white with consistent visual weight.
- Color UI shows ONE swatch + name; no percentages.

**Deep dive:** `web-research/K-design-critique-redesign.md` §3 (Wardrobe Grid) + §6 (Color display), `web-research/H-wardrobe-ux-competitive.md` (industry conventions), `web-research/G-ios-isolation-best-practices.md` §4 (centering + padding)

---

### PR #28 — Confidence-Triaged Review Wall (P1, ~700 LOC)
**Branch:** `feat/multi-pick-review-wall`
**Severity:** HIGH — replaces 6×ItemFormView fatigue with single-screen review
**Migration:** None
**Dependencies:** PR #22 (display) + PR #24 (mapping) + PR #26 (colors) — review wall renders these correctly

**What it does:** Replace the per-item form loop with one Review Wall screen. High-confidence items collapsed (no decisions); low-confidence items auto-expanded with top-3 alternatives + tap-to-confirm. Hide texture/fit/season/occasion behind progressive disclosure.

**Architecture:**
```
Mirror selfie
  → MultiGarmentGridView   (unchanged — pick which garments to keep)
  → ReviewWallView         (NEW — single screen, all 6 items, only low-conf items expanded)
  → Wardrobe (saved)
```

**Files (new):**
- `WardrobeReDo/Views/Capture/ReviewWallView.swift` — main screen
- `WardrobeReDo/Views/Capture/ReviewItemRow.swift` — per-item row, DisclosureGroup
- `WardrobeReDo/Views/Capture/ConfidenceChipPicker.swift` — top-3 inline alternatives + "More…"
- `WardrobeReDo/ViewModels/ReviewWallViewModel.swift` — handles bulk save + per-row category fixes

**Confidence bands:**
| Band | Score range | UI behavior |
|---|---|---|
| Confident | ≥ 0.85, no known-mislabel | Row collapsed, no badge |
| Uncertain | 0.6–0.84 OR known-mislabel | Row collapsed, "Tap to confirm" caption |
| Unsure | < 0.6 | Row auto-expanded, top-3 chip picker visible |

**Footer actions:**
- `Save 6 items` (primary) — saves all
- `Skip review · save anyway` (tertiary) — same effect, marks items with `isReviewPending: true` for later batch-edit
- `Cancel` (toolbar) — discard batch

**Texture/Fit/Season/Occasion progressive disclosure:**
- Hidden from review wall completely
- Saved with model's predictions
- Surfaced via `ItemDetailView` "Add details" button → existing `ItemFormView` in `.sheet`

**Tests:**
- `WardrobeReDoTests/Views/Capture/ReviewWallTests.swift` — confidence-driven expand state, bulk save, skip-review flag.

**Verification:**
- Multi-pick 6 items → land on Review Wall, not 6 sequential forms.
- Save with 0 decisions when all confident.

**Deep dive:** `web-research/K-design-critique-redesign.md` §2 (full design), `web-research/I-form-overwhelm-ml-ux.md`, `web-research/H-wardrobe-ux-competitive.md` (Whering's mass-tagging pattern)

---

### PR #29 — Worn Outfits entity (P1, ~500 LOC + migration)
**Branch:** `feat/worn-outfits`
**Severity:** MEDIUM — new feature, supports user's stated want
**Migration:** `00015_worn_outfits.sql`
**Dependencies:** None (additive)

**What it does:** Promote the source-photo-as-look concept into a first-class `WornOutfit` entity. Add Wardrobe sub-tab.

**Migration `00015_worn_outfits.sql`:**
```sql
create table public.worn_outfits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  source_photo_path text not null,
  source_photo_thumbnail_path text,
  worn_at timestamptz not null default now(),
  notes text,
  created_at timestamptz not null default now()
);

create table public.worn_outfit_items (
  worn_outfit_id uuid references public.worn_outfits(id) on delete cascade,
  wardrobe_item_id uuid references public.wardrobe_items(id) on delete cascade,
  primary key (worn_outfit_id, wardrobe_item_id)
);

alter table public.worn_outfits enable row level security;
alter table public.worn_outfit_items enable row level security;

-- RLS policies (mirror wardrobe_items pattern)
create policy "Users access own worn outfits" on public.worn_outfits
  for all using ((select auth.uid()) = user_id);

create policy "Users access own worn outfit items via worn_outfit"
  on public.worn_outfit_items for all
  using (exists (select 1 from public.worn_outfits wo
    where wo.id = worn_outfit_id and wo.user_id = (select auth.uid())));
```

**Files (new):**
- `WardrobeReDo/Models/WornOutfit.swift`
- `WardrobeReDo/Repositories/WornOutfitRepository.swift`
- `WardrobeReDo/Views/Wardrobe/WornOutfitsTimelineView.swift`
- `WardrobeReDo/Views/Wardrobe/WornOutfitDetailView.swift`
- `WardrobeReDo/Views/Wardrobe/WardrobeRootView.swift` — adds segmented control: [Items] [Worn]
- `WardrobeReDo/ViewModels/WornOutfitsViewModel.swift`

**Behavior:**
- Multi-pick batch save with ≥2 items → auto-create `WornOutfit` linking source photo + items
- Single-item save → no auto-create; "Mark as worn" affordance in `ItemDetailView` toolbar promotes to a 1-item WornOutfit
- Timeline view: vertical scroll of dated `WornOutfitCard`s (full-width source photo + horizontal strip of item cutouts)
- Detail view: hero source photo (zoom-tap) + 2-col grid of item cutouts

**Tests:**
- `WardrobeReDoTests/Repositories/WornOutfitRepositoryTests.swift`
- `WardrobeReDoTests/ViewModels/WornOutfitsViewModelTests.swift`
- Migration round-trip test

**Verification:**
- Multi-pick 6 items → toast "We saved this as a worn outfit" → Wardrobe → Worn tab shows it.

**Deep dive:** `web-research/K-design-critique-redesign.md` §4, `web-research/G-ios-isolation-best-practices.md` §7, `web-research/H-wardrobe-ux-competitive.md` (Looks/Outfits patterns)

---

### PR #30 — Capture telemetry (P2, ~100 LOC)
**Branch:** `chore/capture-telemetry`
**Severity:** LOW — observability
**Migration:** None
**Dependencies:** None

**What it does:** Add structured logging to the capture pipeline so future dogfood failures are diagnosable from logs.

**Files:**
- `MultiGarmentProposalService::makeProposal` — log `rawClass`, `score`, `bbox`, `finalCategory`, `finalSubcategory`
- `AddItemViewModel::applyPrefill` — log which branch fired (rescue / predictedSubcategory / default)
- `ColorExtractionService::extractColors` — log cluster count before/after merge, alpha-threshold rejections
- New `Logger` extension for capture pipeline structured fields

---

## Build cadence

| Build | PRs | Headline |
|---|---|---|
| **5.0** | #22 + #23 + #24 + #25 + #30 | Capture-pipeline correctness — sneakers / sunglasses / belt / texture all pre-fill correctly; cards show real cutouts |
| **5.1** | #26 + #27 | Color overhaul + uniform white-bg cards — biggest visual quality lift |
| **5.2** | #28 | Multi-pick Review Wall — UX paradigm shift |
| **5.3** | #29 | Worn Outfits — new entity |

Each build ships to TestFlight, dogfood iteration, then next.

---

## Risk controls

- Each PR is independently testable; ordering allows shipping #22 alone if #23 hits issues
- PR #23 has a fallback: if `compositeMaskedItem` produces broken cutouts, set `maskedData: nil` for multi-pick (Option B in `agents/D-save-path-supabase.md`) — Wardrobe will fall back to thumbnailPath, ugly but consistent
- PR #24 mapping changes are backward compatible — only ADD/CORRECT cases, don't remove behavior
- PR #26 (color) behind a feature flag for first 24h post-deploy
- PR #29 (worn outfits) is purely additive — no impact on existing wardrobe

---

## Out of scope for Build 5

- RFDETR retraining for sneaker / jeans distinction — requires model work, not v1 (per `J-rfdetr-fashionpedia-classes.md`: those classes don't exist in Fashionpedia ontology)
- Fit prediction (deferred to v1.1 per `ATTRIBUTE_TAXONOMY.md`)
- LLM-generated outfit descriptions (build 7+)
- Calendar view of worn outfits (build 7+, after timeline ships and we have engagement data)
- iCloud sync (out of scope for v1)
- Subcategory combobox redesign (P2, post-Build-5 polish)

---

# Build 6 — Capture Quality v2 (extended from build-5 dogfood)

> Generated 2026-04-27 from build-5 dogfood (10 screenshots — see `.build5-research/screenshots-analysis/build-5-findings.md`).

## Build-5 dogfood deltas

**Confirmed wins**: shoe redundancy (5 items not 6), texture category-default fired (`.denim` for misclassified jeans), telemetry visible in Console.

**Still broken**:
- Subcategory rescue NOT firing for sunglasses + belt + sneakers — root cause: model emits raw classes (`headband`, `boot`) that hit the rescue's nil paths and fall through to defaults
- Wardrobe + Match cards still show source-photo backdrops — root cause: `decodeDETROutput:506` hardcodes `mask: nil`, so the `compositeMaskedItem` from PR #23 always hits the rect-crop fallback
- Color extraction unchanged — expected, PR #26 not yet shipped
- Outfit duplicates ("Retro Spirit BOHEMIAN" twice) — symptom of upstream subcategory bugs producing duplicate items

## Build 6 PR sequence

### PR #31 — Subcategory smart-defaults v3 (P0, ~150 LOC)

**Branch:** `fix/subcategory-smart-defaults-v3`
**Severity:** HIGH — fixes the build-5 sunglasses/belt/sneakers regressions
**Migration:** None
**Dependencies:** None (independent fix)

**What it does:** Apply bbox-position heuristics + user-favoring defaults so the form's pre-fill is right more often than wrong, even when the model is confused.

**Changes:**

| File | Change |
|---|---|
| `WardrobeReDo/ViewModels/AddItemViewModel.swift::applyPrefill` | When `category == .accessory` and `accessorySubcategoryFromRawClass` returns nil, infer subcategory from bbox y-position: y < 0.4 + small height → `.sunglasses`; y in [0.45, 0.65] + thin horizontal → `.belt`; else `.hat`. |
| `WardrobeReDo/Models/Enums/ClothingSubcategory.swift::shoeSubcategoryFromRawClass` | Change `case "boot": return .boots` → `case "boot": return nil`. Lets `.sneakers` category-default fire for boot raw class. Trade-off: real boots get mistagged as sneakers (user corrects). Matches the user-favoring default precedent set by PR #25's `.bottom → .denim`. |
| `WardrobeReDoTests/ViewModels/AddItemViewModelAccessoryRescueTests.swift` | Extend with bbox-heuristic cases: `accessoryFallbackInferssunglassesFromFaceBbox`, `accessoryFallbackInfersBeltFromWaistBbox`, `accessoryFallbackInfersHatFromHighBbox`. |
| `WardrobeReDoTests/Models/Enums/ClothingSubcategoryFashionpediaMappingTests.swift` | Update `shoeSubcategoryRescueMapsBoot` → `shoeSubcategoryRescueDeferToCategoryDefault`. |

**Verification:**
- Multi-pick a sunglasses + belt + sneaker photo → form pre-fills `.sunglasses`, `.belt`, `.sneakers`.

### PR #32 — Wire RFDETR-Seg mask-decode head (P0, ~300 LOC)

**Branch:** `feat/seg-mask-decode`
**Severity:** HIGH — biggest visible quality gain
**Migration:** None
**Dependencies:** PR #23's infrastructure (already merged)

**What it does:** Decode the segmentation-head tensor (`pred_masks`) from `RFDETRSegFashion`'s output. Pipe each per-instance mask into `RawDetection.mask` so `compositeMaskedItem` produces real transparent-bg cutouts.

**Investigation steps before coding:**
1. Inspect `RFDETRSegFashion.mlpackage` model description (`mlmodel_inspect.py` or `MLModel.modelDescription`) to enumerate output names + shapes
2. Identify the `pred_masks` tensor — typically `[1, num_queries, mask_H, mask_W]` for RT-DETR-Seg variants
3. Per-query: extract mask slice, threshold (>0.5), upsample bilinear to source resolution, wrap in `CVPixelBuffer`

**Changes:**

| File | Change |
|---|---|
| `WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift::decodeDETROutput` | Read `maskTensor` (shape `[1, Q, H, W]`), per-query slice → bilinear upsample → threshold → `CVPixelBuffer`. Set `RawDetection.mask = pixelBuffer`. |
| New helper `decodeMask(from:queryIndex:)` | Extract + upsample mask. |
| `WardrobeReDoTests/Services/Extraction/MultiGarmentProposalServiceMaskDecodeTests.swift` (new) | Synthetic mask tensor → assert `decodeMask` returns CVPixelBuffer with correct dimensions + threshold. |

**Verification:**
- Multi-pick a mirror selfie → wardrobe cards show transparent-bg cutouts (no source-photo backdrop)
- Match tab + Outfit cards same

**Risk control:** if mask decode has any failure mode (wrong tensor shape, NaN values, etc.), fall through to existing `mask: nil` path. `compositeMaskedItem` already handles nil with rect-crop fallback. No regression possible.

### PR #26 (from build-5 plan) — Color extraction overhaul (P0, ~350 LOC)

Same scope as planned. Confirmed needed by build-5 dogfood (5 nearly-identical shades, skin-tone leak, 0/1/2% clusters slipping through).

### PR #27 (from build-5 plan) — Uniform white-bg item cards (P0, ~150 LOC)

Same scope as planned. Will pair well with PR #32 (real cutouts on white bg = the intended visual).

## Build 6 cadence

**Build 6.0** = PR #31 + PR #32 + PR #26 + PR #27

These four together transform the look + accuracy of the app:
- Real cutouts everywhere (PR #32)
- White-bg uniform cards showing them (PR #27)
- Editorial single-color UI (PR #26)
- Right pre-fills on accessories + shoes (PR #31)

**Build 6.1** = PR #28 (Review Wall)
**Build 7** = PR #29 (Worn Outfits)

## Build 6 risk controls

- PR #32 has a robust nil-mask fallback (PR #23 already designed for this) — worst case is no regression vs build 5
- PR #31 trade-off (real boots mistagged as sneakers): explicitly chosen, matches PR #25's user-favoring pattern
- PR #26 + #27 can ship without #32 if mask-decode investigation hits a snag


---

## Implementation prompts (drop-in, for use with Agent tool)

If you (Opus 4.7 1M) decide to delegate any PR to a sub-agent, use these self-contained prompts:

### PR #22 prompt
```
Apply PR #22 to branch fix/build-4-display-bugs. Project at /Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/.

Read first:
- docs/plans/2026-04-26-build-5-capture-display-rework.md (PR #22 section)
- .build5-research/agents/E-match-outfit-dedup.md

Tasks:
1. Apply 3-line fix at MatchingViewModel.swift:173, OutfitViewModel.swift:350, OutfitViewModel.swift:359 — change item.thumbnailPath → ItemCardView.displayPath(for: item)
2. Create new Views/Components/ItemThumbnailView.swift — unified component with sizes .small/.medium/.large, internally resolves displayPath. Should compile-check by replacing one usage in ItemCardView.swift.
3. Add WardrobeReDoTests/Views/ItemThumbnailViewTests.swift pinning the displayPath fallback contract.
4. Run xcodegen + xcodebuild test. Both must exit 0.
5. Don't commit. Return exit codes + summary.
```

### PR #23 prompt (similar structure)
```
Apply PR #23 to branch fix/multi-pick-real-cutouts.

Read first:
- docs/plans/2026-04-26-build-5-capture-display-rework.md (PR #23 section)
- .build5-research/web-research/G-ios-isolation-best-practices.md (read the compositeMaskedItem snippet + MaskCleaner snippet)
- .build5-research/agents/C-display-masking-match-outfit.md

Tasks:
1. Replace MultiGarmentProposalService.cropped() with compositeMaskedItem(sourceImage:mask:bbox:) using the code-ready snippet from G-ios-isolation-best-practices.md. The snippet shows how to use CGImage masking + premultipliedLast pixel format.
2. Add new Services/Extraction/MaskCleaner.swift — 3-step CIFilter pipeline (CIColorThreshold → CIMorphologyMinimum r=1 → CIGaussianBlur r=0.5).
3. Update MultiGarmentProposalService.makeProposal (line 776) to invoke compositeMaskedItem with raw.mask.
4. Replace looksLikeShoeRedundancy at lines 682-689 with proximity-based merge (centroids within 0.18 image-width AND y-midpoints within 0.10).
5. Add tests for both new behaviors.
6. Run xcodegen + xcodebuild test.
```

(Other PR prompts follow the same pattern — research file refs + file:line citations + test obligations + non-committing.)

---

## Context-resilience pattern (institutionalize for future projects)

This plan was written to survive context loss. The pattern:

1. **Research workspace at project root:** `.build5-research/` (or similar versioned name per major effort)
2. **`INDEX.md` first:** any reader (human or LLM) opens this file and can navigate
3. **Per-agent files:** keep each piece of research as a self-contained markdown — never inline 800-line research dumps in the plan
4. **Final plan in `docs/plans/`:** version-controlled with code, referencing the workspace
5. **Implementation prompts inside the plan:** so a sub-agent can be spun up with self-contained context per PR
6. **Cross-references everywhere:** `(see X.md §Y)` rather than copy-pasting findings

For future projects, replicate the directory structure:
```
<project-root>/.<effort-name>-research/
├── INDEX.md
├── agents/         # code exploration outputs
├── web-research/   # external research outputs
├── screenshots-analysis/  # user-supplied artifact catalogs
├── supabase/       # (or db/) production-data inspection
└── drafts/         # plan drafts (final lives in docs/plans/)
```

A user instruction template that triggers this pattern:
> "Set up a research workspace for this. Save findings to disk as you go. Index file first. Final plan in docs/plans/. Make it survive context loss."

This makes any large planning effort resumable from disk.
