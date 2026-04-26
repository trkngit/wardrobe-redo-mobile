# Build 4 Dogfood Screenshot Catalog

Source: `/Users/tarkansurav/Downloads/After build 4/` — 10 PNGs, 17:34-17:36 timestamps.

| Image | Subject | Findings |
|---|---|---|
| **IMG_2512** | Multi-pick grid (6 items detected from 1 mirror selfie) | • Two shoe items detected separately (Shoes 92% wide-shot + Shoes 91% close-up of laces) — PR #19's `looksLikeShoeRedundancy` didn't catch • Tops 60% (overshirt+tee layered look) — large area item, would have triggered help tip |
| **IMG_2513** | Item 1 form: Jeans | • Extracted Colors: 5 nearly-identical blues (26%, 23%, 22%, 19%, 9%) • Subcategory: "Shorts" (WRONG — full-length jeans) • Texture: NOT pre-selected (denim should be obvious) |
| **IMG_2514** | Item 2 form: Sneaker (wide shot) | • 5 brown/tan shades (33%, 27%, 19%, 12%, 5%) — same color, different lighting • Subcategory: "Boots" (WRONG — sneakers) • Texture: NOT pre-selected • Fit: nothing selected |
| **IMG_2515** | Item 3 form: Sneaker laces close-up (DUP of #2) | • 5 cream/tan shades (33%, 27%, 21%, 9%, 8%) • Subcategory: "Boots" (WRONG) • Texture: NOT pre-selected |
| **IMG_2516** | Item 4 form: Sunglasses | • 5 brown shades INCLUDING SKIN TONE — bbox includes face skin around glasses • **Last cluster shows 0%** — UI bug • Subcategory: "Hat" (WRONG — PR #19 A3 rescue not firing) • Texture: NOT pre-selected |
| **IMG_2517** | Item 5 form: Belt | • 5 colors (30%, 22%, 17%, 16%, 13%) • Subcategory: "Hat" (WRONG — same accessory rescue bug) • Texture: NOT pre-selected |
| **IMG_2518** | Item 6 form: Layered top + tee detected as ONE T-Shirt | • 5 cream/beige shades (25%, 23%, 22%, 16%, 12%) — palette includes SKIN TONE again • Subcategory: T-Shirt (only inner item — overshirt ignored) |
| **IMG_2519** | Wardrobe view — pre-build-4 saves | • TARGET LOOK: Sneakers card = clean isolated shoe centered on dark gray; Dress Pants = same; T-Shirt + Polo = same • This is the visual target build 5 should match |
| **IMG_2520** | Wardrobe view — build-4 multi-pick session | • CURRENT BROKEN: items show source-photo backdrop, NOT isolated cutouts • PR #20's `displayPath` (maskedImagePath ?? thumbnailPath) is in code, but `maskedImagePath` is nil for these multi-pick items |
| **IMG_2521** | Match tab | • Piece selector (top): T-Shirt, Hat, Hat, Boots, Boots — duplicate items + accessory mislabel + source-photo thumbs (not cutouts) • Outfit cards (bottom): item thumbs are source photos, not cutouts • Two outfit cards both "Leather & Shadow EDGY 80" — possible dedup miss |

## Cross-Cutting Bugs Found

### User-listed (confirmed)
1. Shoes detected separately ✓ (IMG_2512)
2. Color shades all near-identical ✓ (IMG_2513-18)
3. Grid view not unified white-bg with centered cutouts ✓ (IMG_2520)
4. Sneakers → Boots ✓ (IMG_2514, 2515)
5. Texture not filled ✓ (all forms)
6. Items not isolated from body ✓ (IMG_2520, IMG_2521)

### Found beyond user's list
7. **Match tab piece selector** uses source-photo thumbs (PR #20 only fixed Wardrobe grid)
8. **Outfit cards** use source-photo thumbs — same root cause
9. **Sunglasses palette has skin tone** — soft-edge mask leakage
10. **0% color cluster shown** — no min-% filter
11. **Possible outfit dedup miss** — two "Leather & Shadow / EDGY / 80" cards
12. **Shorts subcategory for full-length jeans** — RFDETR misclassification, not just mapping
13. **Sunglasses → Hat** AND **Belt → Hat** — PR #19 A3 rescue is bypassed because predictedSubcategory != nil (= .hat upstream)
14. **Layered look detection** — model can't split, no UI affordance to split into 2 items after detection
