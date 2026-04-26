# Build 5 Dogfood Catalog (10 screenshots, 2026-04-27 00:01-00:03)

| Image | Subject | Build-4 → Build-5 delta |
|---|---|---|
| **IMG_2540** | Multi-pick grid | **WIN — only 5 items** (not 6 like build 4). Shoe redundancy v2 (PR #23) fired correctly. |
| **IMG_2541** | Item 1: Jeans form (top half) | • Subcategory: **"Shorts" (still wrong)** — model misclassification, not fixable in mapping<br>• **WIN — Texture: "Denim" pre-selected** (PR #25's category-default fired)<br>• Colors: still 5 nearly-identical blue/gray shades (PR #26 pending) |
| **IMG_2542** | Item 1: Jeans form (bottom half) | • Texture Denim confirmed selected<br>• Seasons (Spring + Summer) + Occasions (Casual + Date) pre-filled correctly<br>• Fit: nothing selected (expected — v1.1) |
| **IMG_2543** | Item 2: Sneaker form | • Subcategory: **"Boots" (still wrong)** — sneaker misclassified<br>• 5 nearly-identical brown/tan shades<br>• Texture: not pre-selected (no shoe rule, expected) |
| **IMG_2544** | Item 3: Sunglasses form | • Subcategory: **"Hat" (still wrong)** — accessory rescue did NOT fire<br>• 5 brown/tan shades INCLUDING SKIN TONE<br>• **0% cluster shown** — min-% filter still missing |
| **IMG_2545** | Item 4: Belt form | • Subcategory: **"Hat" (still wrong)** — same accessory rescue gap<br>• 5 colors at 53/23/12/9/2% — **2% slipping through** (lower threshold than 0%) |
| **IMG_2546** | Item 5: Layered top form | • Subcategory: T-Shirt ✓<br>• 5 colors include yellow @ 1% (likely phone screen reflection in mirror selfie)<br>• `.tshirt` reasonable for layered look — model can't split layers |
| **IMG_2547** | Wardrobe (session view) | Shoe card shows **source-photo backdrop** (rect-crop, not cutout) — mask-decode wiring still latent |
| **IMG_2548** | Wardrobe scrolled | Belt + Tee cards show source-photo backdrops — same root cause |
| **IMG_2549** | Match tab | Item strip: T-Shirt, **Hat, Hat, Boots, Shorts** — labels reflect upstream subcategory bugs<br>Two outfit cards both "Retro Spirit BOHEMIAN" (82, 80) — duplicate-looking outfits because the items they contain were duplicated/mislabeled at capture |

## Confirmed wins from build 5

1. ✅ **Shoe redundancy v2 (PR #23)** — single-foot photos now produce 1 shoe item (was 2)
2. ✅ **Texture category-default (PR #25)** — `.denim` pre-fills for misclassified jeans
3. ✅ **Telemetry (PR #26)** — `os.Logger` lines emitting in capture pipeline (Console.app verified)

## Unfixed bugs (still visible)

### A. Subcategory rescue NOT firing for accessories + shoes (HIGH)

Despite PR #24's inverted rescue logic, the form still pre-fills `.hat` for sunglasses + belt and `.boots` for sneakers.

**Root-cause hypothesis** (to verify with build-5's new telemetry): the model is emitting RAW classes that we don't map. Specifically:
- For sunglasses + belt: likely emitting `headband`, `tie`, `glove`, or `ring` — all valid Fashionpedia accessory classes that have NO entry in `accessorySubcategoryFromRawClass` and NO subcategory mapping in `fromFashionpediaClass`. So both return nil, and `applyPrefill` falls through to `defaultSubcategory(.accessory) = .hat`.
- For sneakers: likely emitting `boot` raw class (the model's confusion between sneaker silhouettes and ankle boots, common in Fashionpedia training data). `shoeSubcategoryFromRawClass("boot")` returns `.boots`, locking in the wrong label.

**Fix options:**

1. **Bbox-position heuristic** (recommended) — when rescue returns nil for an accessory, infer from bbox y-position:
   - bbox y < 0.4 + small height → likely face accessory → `.sunglasses`
   - bbox y ≈ 0.5 + thin horizontal → likely waist → `.belt`
   - else default `.hat`

2. **Sneaker user-favoring default** — change `shoeSubcategoryFromRawClass("boot")` to return nil instead of `.boots`. Lets the `.sneakers` category-default fire. Trade-off: real boots get mistagged as sneakers; user corrects.

### B. Color extraction still raw (BLOCKER for v6)

Already in plan as PR #26. Build 5 confirms ALL 4 issues:
- 5 nearly-identical shades (5 brown/tan for the sneaker; 5 blue/gray for jeans)
- Skin tone in sunglasses palette (IMG_2544)
- 0% cluster shown (IMG_2544)
- 1-2% clusters slipping through (IMG_2545: 2%, IMG_2546: 1%)

### C. Source-photo backdrop on cards (BLOCKER for v6)

PR #23 landed the `compositeMaskedItem` infrastructure, but `decodeDETROutput:506` still hardcodes `mask: nil`. So the wardrobe + match views still serve rect-crop PNGs labeled "masked." Was scoped as v1.1 follow-up; promoting to build 6 since it's the visible quality blocker.

### D. Outfit duplicates (MEDIUM)

IMG_2549: two "Retro Spirit BOHEMIAN" outfits at 82 + 80 score. Caused by two `.boots` items in DB (same physical sneaker pair, both misclassified). Dedup is item-id-set based; same items → 1 outfit, but DIFFERENT items with same archetype + similar scores → two cards. Fixes upstream when subcategory mapping is correct.

## Plan extension (build 6)

Beyond the existing PR #26 (color) + PR #27 (cards) + PR #28 (review wall) + PR #29 (worn outfits), add two new PRs:

- **PR #31** — Subcategory smart-defaults v3: bbox-position heuristic for accessory rescue + sneaker user-favoring default. ~150 LOC. Targets bug A.
- **PR #32** — Wire RFDETR-Seg mask-decode head. Promotes the v1.1 follow-up to build 6 because it's the highest-impact visible quality gain. ~250-400 LOC, depends on inspecting the model's `pred_masks` tensor shape.

Recommended build-6 cut: PR #31 + PR #32 + PR #26 + PR #27 → all four ship as one TestFlight build for maximum dogfood signal.
