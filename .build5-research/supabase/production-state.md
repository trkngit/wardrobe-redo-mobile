# Supabase Production State — Build 4 Multi-Pick Batch Audit

Project: `xavxlsutdcvllbvmxoma` (region eu-west-1, Postgres 17.6).

## The build-4 multi-pick batch
`source_photo_id = e711569e-6a5d-4851-a7ef-23405f716c65`, created 2026-04-26 14:34–14:35.
6 items saved from one mirror selfie:

| Item | Category | Subcategory | bbox (x, y, w, h) | Texture | First Color |
|---|---|---|---|---|---|
| Jeans (full-length, displayed as) | bottom | **shorts** ❌ | (0.30, 0.52, 0.24, 0.30) | null ❌ | #332E2C gray 26% (shadow) |
| Wide-shot of shoe | shoe | **boots** ❌ | (0.26, 0.79, 0.15, 0.04) | null ❌ | #58524A gray 33.8% |
| Close-up of shoe | shoe | **boots** ❌ | (0.45, 0.81, 0.07, 0.05) | null ❌ | #57493C orange 33% |
| Sunglasses | accessory | **hat** ❌ | (0.40, 0.32, 0.10, 0.02) | null ❌ | #3B342E orange 26.8% |
| Belt | accessory | **hat** ❌ | (0.37, 0.52, 0.11, 0.02) | null ❌ | #2F2C29 gray 30% |
| Tee (under overshirt) | top | tshirt ✅ | (0.29, 0.35, 0.29, 0.24) | null ❌ | #C6B9A1 cream 25.8% |

## CRITICAL FINDINGS

### 1. `maskedImagePath` IS populated, NOT an upload bug
All 6 items have `masked_image_path` populated, like `{userId}/{itemId}/masked.png`.
✓ Upload happens correctly.
**The bug must be in the CONTENT of masked.png** OR in a display code path that ignores `maskedImagePath`.

### 2. Bounding boxes are TINY for shoes + accessories
- Shoe wide-shot bbox: 0.04 height = 4% of frame (probably just the laces/top of shoe in a body shot)
- Shoe close-up bbox: 0.05 height
- Sunglasses bbox: 0.02 height (tiny!)
- Belt bbox: 0.02 height (tiny!)

These are extreme aspect ratios. When centered + padded for the wardrobe card, they will appear EITHER tiny (if scaled to bbox-fit) OR distorted (if scaled to fit card).

### 3. Two shoe bboxes don't overlap at all
- Wide-shot: x=[0.26, 0.41]
- Close-up: x=[0.45, 0.52]
- Both at y≈0.80 (bottom)
- **Bug F revised:** they don't overlap → `looksLikeShoeRedundancy` (>70% containment) correctly returns 0. But the model produced 2 separate detections of what's physically ONE shoe at different image locations. The fix needs a different strategy: distance-based merging, OR a per-class instance-count cap, OR confidence-based suppression.

Wait — actually: looking at the bboxes, they could be the wearer's LEFT and RIGHT foot in a body photo. That's TWO actual shoes (one pair), not one shoe detected twice. PR #19 was supposed to handle this with `looksLikeShoePair` (similar Y, similar size, close gap). Let me check:
- Y midpoints: 0.79+0.02=0.81 and 0.81+0.025=0.835 — close (Δ=0.025)
- Sizes: w=0.154 vs 0.072 — TWO X DIFFERENT (close-up is half the size)
- Gap: x=0.41 vs x=0.45, gap=0.04 — close
- The size-similarity check would FAIL here (close-up is half size) → looksLikeShoePair returns false → both kept

**So the bug is:** these aren't visually-similar shoe pair detections; one is much smaller than the other. They're either two parts of the same shoe (heel + toe?) or two perspectives of the foot. PR #19's pair-check rejected them as a pair, but they should be merged anyway.

### 4. Dominant colors include lots of shadow/dark neutrals
First-color analysis for the 6 items:
- 4 of 6 first-colors have lightness < 0.32 (shadow-dominated)
- 4 of 6 first-colors have saturation < 0.13 (very desaturated)
- Family classification: gray/orange across the board, even for "blue jeans" or "cream tee"

**Insight:** k-means is finding shadow regions as the dominant cluster because shadows take up significant pixel area in real-world garment photos. This is the source of the "5 shades of blue" / "5 shades of brown" complaint — the shades aren't really shades of the garment color, they're shades of GARMENT + SHADOW.

### 5. `texture: null` on all 6 items — Bug E confirmed
Even for jeans (which would have rule-derived `.denim`), texture is null in DB. The texture rules pipeline isn't firing for multi-pick. Either:
- `FeatureFlags.isAttributeDetectionEnabled` is off
- Rules engine fails silently in the multi-pick path
- The category-default fallback (`.bottom → .jeans`) doesn't fire because subcategory is `.shorts` (where there's no rule for denim)

The shorts rule isn't there in `RulesTable.texture` — only `.jeans` maps to `.denim`. Since `subcategory == .shorts` (model's wrong output), the rules lookup misses.

### 6. detected_attributes provenance — most "ai"
For the multi-pick batch:
- 5 of 6 items have `subcategory: ai` (user accepted the wrong AI label)
- 1 item has `subcategory: user` (user manually fixed)
- For the wrong AI labels, user just clicked save without correcting

**UX implication:** the form is so overwhelming that users CLICK SAVE without correcting wrong predictions. We need:
- Better defaults so AI predictions are actually correct
- Easier correction UI (chip group with predictions on top)
- Bulk-confirm flow that surfaces only items with low-confidence predictions

## Storage path conventions (current)

- Source: `{userId}/source/{sourcePhotoId}/original.jpg` (full source photo, JPEG)
- Thumbnail: `{userId}/{itemId}/thumb.jpg` (per-item thumbnail of source-photo crop?)
- Masked: `{userId}/{itemId}/masked.png` (per-item — what's IN it?)

## Open question: what IS in the masked.png?

Possibilities:
1. ✅ Garment cutout with transparent background (correct case — pre-build-3 saves)
2. ❌ Source-photo bbox crop with rectangle (rectangular crop, no garment isolation)
3. ❌ Source-photo with non-bbox areas zeroed (cropped to bbox but solid bg)

Given IMG_2520 shows source-photo backdrop on the wardrobe cards, hypothesis #2 or #3.

The on-disk file would tell us. Let me verify by checking storage object metadata next.

## Action items for build 5

1. **Re-mask multi-pick items** — produce true transparent-bg PNGs from `MaskProposal.maskedImage`
2. **Fix subcategory mapping** for sneakers, sunglasses, belt
3. **Improve color extraction** to suppress shadow-dominated clusters
4. **Force texture rules to fire** even when subcategory is wrong (use category default mapping)
5. **Distance-based shoe redundancy** (or confidence-suppression on N-shoe detections)
6. **Bulk-confirm UI** for multi-pick to reduce form fatigue
