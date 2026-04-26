# J. RFDETRSegFashion → ClothingSubcategory Class Mapping (Authoritative)

**Status:** Researched 2026-04-26 against the canonical Fashionpedia annotation file (`instances_attributes_val2020.json`, downloaded from the official AWS mirror) and the project's bundled label list in `MultiGarmentProposalService.fashionpediaLabels`.

**TL;DR for the dogfood failures:**

1. **Sunglasses → "Hat"**, **Belt → "Hat"** — the model emits `glasses` and `belt` correctly (those labels exist verbatim in `fashionpediaLabels`). The bug is in `AddItemViewModel.applyPrefill`: when the predicted subcategory's `.category` doesn't match the resolved `category`, it falls through `accessorySubcategoryFromRawClass` and then to `defaultSubcategory(.accessory) = .hat`. **The mappings in `ClothingSubcategory.fromFashionpediaClass` and `accessorySubcategoryFromRawClass` are correct** — the failure is elsewhere (low-confidence category, category-subcategory mismatch, or the subcategory branch silently overriding the rescue). See section 6.
2. **Sneakers → "Boots"** — Fashionpedia has **no sneaker class**. Class id 23 is just `shoe`. Sneaker/boot/heel are **attributes** (`nickname` super-category), not categories. The model literally cannot distinguish them with the segmentation head alone.
3. **Jeans → "Shorts"** — Fashionpedia has **no jeans class**. Class id 6 is just `pants`; `jeans` is an **attribute** (`nickname:jeans`, attribute id 36). The "Shorts" output for full-length jeans is a **model error** (length boundary confusion in the training data, not a labeling issue), not a taxonomy issue.

The fix story splits into two parts: **mapping bugs** (sections 6.1–6.2 — fix `applyPrefill` so accessory rescue fires; add the few missing label aliases) and **model retraining** (section 6.3 — Fashionpedia categories are too coarse for our app's `ClothingSubcategory` enum, period).

---

## Complete Class List (33-class trained model + 13-class extension we DON'T receive)

The bundled `RFDETRSegFashion.mlmodelc` was trained on a **33-class subset** of Fashionpedia — main apparel + accessories, excluding all 19 garment-parts decoration classes (collar, lapel, sleeve, pocket, neckline, buckle, zipper, applique, bead, bow, flower, fringe, ribbon, rivet, ruffle, sequin, tassel, hood, epaulette). The Swift code in `MultiGarmentProposalService.fashionpediaLabels` is the source of truth for what indices the model emits.

### Authoritative class table

| FP id | Local label (model emits) | Canonical Fashionpedia name | Supercategory | Currently mapped → ClothingSubcategory |
|---|---|---|---|---|
| 0 | `shirt_blouse` | `shirt, blouse` | upperbody | nil (combo class — not in switch) |
| 1 | `top_t-shirt_sweatshirt` | `top, t-shirt, sweatshirt` | upperbody | nil (combo class — not in switch) |
| 2 | `sweater` | `sweater` | upperbody | `.sweater` |
| 3 | `cardigan` | `cardigan` | upperbody | `.cardigan` |
| 4 | `jacket` | `jacket` | upperbody (outerwear) | nil (ambiguous — bomber/leather/puffer/...) |
| 5 | `vest` | `vest` | upperbody | nil (no `.vest` enum case) |
| 6 | `coat` | `coat` | wholebody | nil (ambiguous — trench/parka/winter/...) |
| 7 | `cape` | `cape` | wholebody | nil (no `.cape` case) |
| 8 | `pants` | `pants` | lowerbody | nil (ambiguous — jeans/chinos/dress) |
| 9 | `shorts` | `shorts` | lowerbody | `.shorts` |
| 10 | `skirt` | `skirt` | lowerbody | `.skirt` |
| 11 | `tights_stockings` | `tights, stockings` | legs and feet | nil (closest is `.leggings`, deliberate skip) |
| 12 | `dress` | `dress` | wholebody | nil (ambiguous — maxi/mini/cocktail/...) |
| 13 | `jumpsuit` | `jumpsuit` | wholebody | nil (no `.jumpsuit` case) |
| 14 | `shoe` | `shoe` | legs and feet | nil (ambiguous — sneaker/loafer/heel/...) |
| 15 | `boot` | `boot` | legs and feet | `.boots` |
| 16 | `sandal` | `sandal` | legs and feet | `.sandals` |
| 17 | `sock` | `sock` | legs and feet | excluded (no `.sock` case) |
| 18 | `leg_warmer` | `leg warmer` | legs and feet | excluded |
| 19 | `glasses` | `glasses` | head | `.sunglasses` |
| 20 | `hat` | `hat` | head | `.hat` |
| 21 | `headband` | `headband, head covering, hair accessory` | head | nil (only `.fedoraHat`/`.baseballCap` are close but wrong) |
| 22 | `scarf` | `scarf` | others | `.scarf` |
| 23 | `tie` | `tie` | neck | nil (no `.tie` case) |
| 24 | `bag_wallet` | `bag, wallet` | others | `.bag` |
| 25 | `belt` | `belt` | waist | `.belt` |
| 26 | `glove` | `glove` | arms and hands | nil (no `.gloves` case in this enum) |
| 27 | `watch` | `watch` | arms and hands | `.watch` |
| 28 | `ring` | `ring` | (jewelry) | nil (no `.ring` case) |
| 29 | `bracelet` | `bracelet` | (jewelry) | `.bracelet` |
| 30 | `earring` | `earring` | (jewelry) | `.earrings` |
| 31 | `necklace` | `necklace` | (jewelry) | `.necklace` |
| 32 | `umbrella` | `umbrella` | others | excluded |

Indices 33–90 are unfitted COCO classifier slots from the rfdetr 1.4 quirk — the model can produce them as argmax, but `MultiGarmentProposalService.labelForIndex` returns `"class_N"` for those, so they never claim a category.

### What's NOT in our 33-class model (and why)

The full Fashionpedia ontology has 46 classes. The 13 we don't have are all **garment parts and decorations** (ids 27-45 in the canonical Fashionpedia ordering): `hood`, `collar`, `lapel`, `epaulette`, `sleeve`, `pocket`, `neckline`, `buckle`, `zipper`, `applique`, `bead`, `bow`, `flower`, `fringe`, `ribbon`, `rivet`, `ruffle`, `sequin`, `tassel`. None of those map to a wardrobe `ClothingSubcategory` so excluding them from the trained model is correct.

### Critical labels that look right but ARE NOT in the model

- **There is no `t-shirt` label.** Fashionpedia merges T-shirts into `top, t-shirt, sweatshirt` (combo class, id 1, model label `top_t-shirt_sweatshirt`). The current `fromFashionpediaClass` switch has cases for `"t-shirt"` and `"sweatshirt"` and **neither will ever fire** because the model doesn't emit those tokens. Same for `"top"`. Same for `"shirt"` (the model emits `shirt_blouse`, not `shirt`).
- **There is no `sunglasses` label.** Fashionpedia uses `glasses` (id 13). The case `"sunglasses"` in the switch is dead code (harmless but misleading).
- **There is no `cap` label.** Fashionpedia uses `hat` (id 14) for everything from baseball caps to fedoras to beanies. Cap-vs-fedora distinction lives in attributes, not categories.
- **There is no `pants` distinguished from `jeans`.** Same reason: `jeans` is attribute id 36 (`nickname:jeans`), not a separate category.
- **There is no `gown` label.** Fashionpedia maps gowns into `dress` (id 10). The case `"gown"` in `ClothingCategory.fromFashionpediaClass` is dead code.
- **There is no `purse`, `wallet`, or `bag` (alone) label.** They're all `bag, wallet` (id 24), model label `bag_wallet`. The cases `"bag"`, `"wallet"`, `"purse"` in our category mapping are dead code.
- **There is no `trousers` label.** Fashionpedia uses `pants`. The case `"trousers"` is dead code.

---

## 1. Fashionpedia Dataset (Authoritative Reference)

- **Paper:** Jia, Shi, Sundaram, et al. *Fashionpedia: Ontology, Segmentation, and an Attribute Localization Dataset.* ECCV 2020.
- **Project page:** https://fashionpedia.github.io/home/
- **GitHub mirror (CVDF):** https://github.com/cvdfoundation/fashionpedia
- **Hugging Face mirror:** https://huggingface.co/datasets/detection-datasets/fashionpedia
- **Python API:** https://github.com/KMnP/fashionpedia-api
- **Dataset structure (verified by direct download):** 46 categories (27 main apparel + 19 apparel parts), 294 fine-grained attributes across 9 super-categories, ~48K everyday and celebrity images with COCO-format segmentation masks.

### Full 46-class ontology, exact strings (downloaded from `instances_attributes_val2020.json`)

```
id  name                                            supercategory
 0  shirt, blouse                                   upperbody
 1  top, t-shirt, sweatshirt                        upperbody
 2  sweater                                         upperbody
 3  cardigan                                        upperbody
 4  jacket                                          upperbody
 5  vest                                            upperbody
 6  pants                                           lowerbody
 7  shorts                                          lowerbody
 8  skirt                                           lowerbody
 9  coat                                            wholebody
10  dress                                           wholebody
11  jumpsuit                                        wholebody
12  cape                                            wholebody
13  glasses                                         head
14  hat                                             head
15  headband, head covering, hair accessory         head
16  tie                                             neck
17  glove                                           arms and hands
18  watch                                           arms and hands
19  belt                                            waist
20  leg warmer                                      legs and feet
21  tights, stockings                               legs and feet
22  sock                                            legs and feet
23  shoe                                            legs and feet
24  bag, wallet                                     others
25  scarf                                           others
26  umbrella                                        others
27  hood                                            garment parts
28  collar                                          garment parts
29  lapel                                           garment parts
30  epaulette                                       garment parts
31  sleeve                                          garment parts
32  pocket                                          garment parts
33  neckline                                        garment parts
34  buckle                                          closures
35  zipper                                          closures
36  applique                                        decorations
37  bead                                            decorations
38  bow                                             decorations
39  flower                                          decorations
40  fringe                                          decorations
41  ribbon                                          decorations
42  rivet                                           decorations
43  ruffle                                          decorations
44  sequin                                          decorations
45  tassel                                          decorations
```

Note the 6 multi-word names with commas (ids 0, 1, 15, 21, 24). Our local label list snake-cases ids 0, 1, 21, 24 (`shirt_blouse`, `top_t-shirt_sweatshirt`, `tights_stockings`, `bag_wallet`) and shortens id 15 to `headband`.

### How sneakers / boots / jeans are encoded — they're attributes, NOT categories

Fashionpedia's `nickname` super-category contains 153 fine-grained "what type of garment" attributes, each tied to a parent category. **`shoe` (cat id 23) has no nickname attributes that distinguish sneakers/boots/heels** — the dataset annotators were asked for category + masks at the category level, not nickname for footwear. Boot is a separate category (id 15 in our local list, comes from a different supercategory partition). For pants, jeans/chinos/etc. are nicknames:

```
attribute id  name (parent)        notes
36           jeans                  → cat 6 (pants)
37           sweatpants             → cat 6
38           leggings               → cat 6
39           hip-huggers (pants)    → cat 6
40           cargo (pants)          → cat 6
41           culottes               → cat 6
42           capri (pants)          → cat 6
43           harem (pants)          → cat 6
44           sailor (pants)         → cat 6
45           jodhpur                → cat 6
46           peg (pants)            → cat 6
47           camo (pants)           → cat 6
48           track (pants)          → cat 6
49           crop (pants)           → cat 6
```

Same pattern for shorts (50-61), skirts (62-78), coats (79-94), dresses (95-113). And — critically for the user's third bug — **there is no `nickname` attribute that says "sneaker" or "boot" attached to category `shoe`**. Fashionpedia distinguishes boot vs shoe at the **category level only** (boot=id 15 here / id 23 in the canonical 46-class list is the umbrella `shoe` term), and provides no fine-grained sneaker-vs-loafer-vs-heel attribute at all.

### What this means for our Swift mapping

Our `ClothingSubcategory` enum has 80+ cases (sneakers, jeans, chinos, dressPants, dressShoes, loafers, heels, ...). Fashionpedia's 33 trained classes can only commit to about **8 of those at the subcategory level** with full confidence:
- `shorts` → `.shorts`
- `skirt` → `.skirt`
- `boot` → `.boots`
- `sandal` → `.sandals`
- `glasses` → `.sunglasses` (with a known caveat: also covers reading glasses)
- `belt` → `.belt`
- `watch` → `.watch`
- `bracelet` → `.bracelet`, `earring` → `.earrings`, `necklace` → `.necklace`, `bag_wallet` → `.bag`

Everything else needs either a **secondary classifier head** (attribute model) or **post-processing heuristics** based on bbox shape. The current Swift mapping is correct in returning `nil` for ambiguous categories — that part of the design is sound.

---

## 2. RF-DETR / RT-DETR Segmentation (Architecture Notes)

- **GitHub:** https://github.com/roboflow/rf-detr (ICLR 2026, Apache 2.0)
- **Roboflow model card:** https://roboflow.com/model/rf-detr-segmentation
- **Hugging Face Space:** https://huggingface.co/spaces/Roboflow/RF-DETR
- **Backbone:** DINOv2 ViT
- **Segmentation head:** MaskDINO-inspired
- **Released:** Oct 2, 2025 (segmentation variant)

### Why we have 33 fitted classes but 91 logit slots

This is a known rfdetr 1.4 quirk, already documented in the codebase:

> rfdetr 1.4 reinitialises the classifier head to the pretrained COCO layout (91 slots) during `Model.train`, regardless of the `num_classes` we pass at construction.

GitHub issues confirming the bug: [#108](https://github.com/facebookresearch/detr/issues/108), [#330](https://github.com/roboflow/rf-detr/issues/330), [#509](https://github.com/roboflow/rf-detr/issues/509). The defensive `class_N` fallback in `MultiGarmentProposalService.labelForIndex` for argmax≥33 is the right fix.

### Did Roboflow ship a Fashionpedia-trained variant publicly?

**No.** The Roboflow team has not published an official Fashionpedia checkpoint. RF-DETR is published as a generic detection/segmentation framework, COCO-pretrained. The Wardrobe Re-Do team's `RFDETRSegFashion` model is a **custom fine-tune** done in `notebooks/training/2026-04-multi-garment.ipynb` (per the project comment). Conclusion: there's no upstream class list to defer to — our local `fashionpediaLabels` array IS the authoritative spec for what indices this app's model emits.

### Output format quirk for our Swift decoder

RF-DETR Seg's coremltools export hasn't fully stabilised. The current decoder probes a list of likely names (`pred_boxes` / `pred_logits` / `pred_masks` etc.) — that's already the right defensive posture. The mask head was deliberately not decoded in v1 (bbox crops only). Worth noting for any reader: if the export ever changes its tensor names, the decoder needs an update — but the Fashionpedia label list itself is independent of that.

---

## 3. Common Misclassification Patterns

Based on Fashionpedia paper analysis, RF-DETR issue tracker, and general fine-grained fashion-CV literature (UT Zappos50K, FashionFormer):

### Sneakers ↔ Boots ↔ Sandals (categories 14/15/16)

- **Root cause:** category-level only — the model has no signal beyond mask shape and texture for shoe sub-types.
- **Documented issue:** Fashionpedia paper, Section 4.3: footwear masks are "the most complex amongst five datasets" because of articulated leg+foot geometry. Boot/shoe/sandal masks routinely overlap when ankles are partially visible.
- **Specific failure mode (Wardrobe Re-Do dogfood):** model trained on Fashionpedia's 33 classes produces `shoe` for both sneakers and dress shoes; the Swift mapping returns `nil` for `shoe`, so `predictedSubcategory` is nil and `defaultSubcategory(.shoe) = .sneakers` fires. **For sneakers this looks right, but** if anything sets `predictedSubcategory` to `.boots` (which `boot`-class detections do) and the model misclassifies a high-top sneaker as `boot`, the user sees "Boots" when they meant sneakers.
- **No public confusion matrix exists.** The Fashionpedia ECCV paper reports mAP per category (Table 5) but not pairwise confusion rates. UT Zappos50K reports ~85% boot vs sneaker accuracy on a binary classifier with full-shoe crops — degrades on bbox crops.

### Pants ↔ Shorts (categories 6/7)

- **Root cause:** the boundary is **garment length only**. Fashionpedia annotators were given a length attribute (`nickname:short (shorts)`, `cargo (shorts)`, etc.) for shorts, but **the category-level decision is binary** — the model has no continuous "length" signal at the category head; it has to memorize "calf-or-below=pants, mid-thigh=shorts" from masks alone.
- **Specific failure mode (jeans → shorts):** if the user is sitting, kneeling, or wearing baggy jeans, the bbox aspect ratio looks more like the trained `shorts` distribution than the trained `pants` distribution. This is an annotation-density issue (more shorts in standing/walking poses, more pants in seated poses, less data on edge cases), not a label-string issue.
- **Mitigation options:** (a) a secondary length classifier on the cropped mask; (b) bbox aspect ratio heuristic (h/w > 1.5 → assume pants, even if model said shorts); (c) re-train with length attribute as auxiliary supervision.

### Belt / Sunglasses pre-filling as Hat (Wardrobe Re-Do specific)

- **Root cause is NOT in the Fashionpedia mapping.** The label `belt` and `glasses` are emitted correctly by the model and the Swift switches DO map them to `.belt` and `.sunglasses`.
- **The bug is in `AddItemViewModel.applyPrefill`** (lines 1036-1045 in `WardrobeReDo/ViewModels/AddItemViewModel.swift`). The control flow:
  1. If `proposal.predictedSubcategory` is non-nil AND its `.category == category` → use it.
  2. Else if `category == .accessory` AND `accessorySubcategoryFromRawClass(...)` returns non-nil → use rescue.
  3. Else → `defaultSubcategory(category)`. For `.accessory`, that's `.hat`.
- **The two paths where the user sees "Hat":**
  - **Path A (low confidence on category):** `applyPrefill` first computes `category`. If `predictedCategoryConfidence < AttributePrefill.shouldPrefill`'s threshold (0.80), `category = .top` falls through. Now even though `proposal.predictedSubcategory == .belt`, `.belt.category == .accessory != .top`, so the equality check fails, the rescue's `category == .accessory` guard fails too, and we end at `defaultSubcategory(.top) = .tshirt`. (This would manifest as "T-Shirt" not "Hat" — so this is NOT the dogfood bug.)
  - **Path B (low subcategory mapping):** `category` resolves correctly to `.accessory`, but for some labels that DON'T have a subcategory mapping (e.g., `headband`, `glove`, `tie`, `ring`), the path-1 check `proposal.predictedSubcategory` is nil. The rescue mapping then tries — but the rescue lookup at line 295 of `ClothingSubcategory.swift` is keyed on the **lowercased raw class string**. Let's verify against the actual emitted strings:
    - Emitted `glasses` → rescue case `"glasses"` → returns `.sunglasses`. **This works.**
    - Emitted `belt` → rescue case `"belt"` → returns `.belt`. **This works.**
  - **So if both paths look right, why is the user seeing Hat?** Two leading hypotheses:
    1. **Confidence threshold for category**. If `predictedCategoryConfidence < 0.80`, `category = .top` is hard-coded (line 1018 of `AddItemViewModel.swift`), and the rescue gate `category == .accessory` never fires. The user would see `.tshirt` though, not `.hat`. UNLESS — they also tapped the category picker and changed it to Accessories, at which point the picker's placeholder is `.hat` (the first-listed accessory case).
    2. **Multi-pick proposal with mixed labels**. If the model returned multiple proposals (one for the actual belt, one for the model's mistaken hat detection on the head/face), and the wrong one is selected, "Hat" is real. Verify by checking telemetry — does `modelClassRaw` say `belt` or `hat` for the failing items?
- **Fix lever:** Audit the path. Specifically, log `(modelClassRaw, predictedCategory, predictedCategoryConfidence, predictedSubcategory)` in `applyPrefill` and read the failing items' telemetry. **The mapping itself is fine; the bug is upstream.**

---

## 4. Mapping-Strategy Best Practices for Fine-Grained → Coarse CV Taxonomies

The general lesson from FashionFormer (CVPR 2023), DETR-based clothing models (CVPRW 2023), and the UT Zappos50K research line:

1. **Don't pretend the categories distinguish things they don't.** If Fashionpedia's `shoe` covers sneaker+loafer+heel, the **honest** mapping is `shoe → nil` (use the category default `.sneakers` only as a last-resort placeholder, surface the uncertainty in the UI). The current Swift code does this correctly.
2. **Use a separate fine-grained head for the distinctions you care about.** The project already has `AttributeClassifierService` for texture + fit. Extending it to predict shoe-type and pants-type would be the production fix for sneaker/boot/jeans/chinos. Plan: Phase 6 of the auto-attribute-detection plan, but limited to texture in v1.
3. **Confidence-thresholded fallback is correct, but the threshold should be PER-FIELD.** The current code uses `AttributePrefill.shouldPrefill` (a single threshold). For ambiguous categories (`shoe`, `pants`), you want a HIGHER threshold for category acceptance because the downstream subcategory default is non-trivially wrong for half the population. For unambiguous categories (`belt`, `glasses`), a LOWER threshold is fine — the worst case is "user sees the prefill and corrects it."
4. **Don't return a default subcategory inside `applyPrefill`. Return `nil` and let the picker show "Choose..."** This is the clean fix for the Hat bug. The current `defaultSubcategory(.accessory) = .hat` plants false confidence: the user reads "Hat" as the model's answer, but it's actually the placeholder. UI nit, real impact.
5. **One-to-many mapping with bbox-shape post-processing is fine but should be transparent.** For `shoe` → `.sneakers OR .boots`, the heuristic could be "if bbox h/w > 1.2 → boots, else → sneakers." Document the heuristic in the source — don't leave a future maintainer to reverse-engineer it.

---

## 5. Confusion-Matrix Data — What Is and Isn't Public

- **Fashionpedia paper Table 5** reports per-class mAP at IoU=0.5 for the SpineNet baseline. Top-performing classes: `dress` (66.7), `pants` (62.5), `coat` (58.3). Worst-performing: `lapel` (12.1), `epaulette` (8.4), `bow` (5.2). **No pairwise confusion matrix is published.**
- **No reproducible RF-DETR + Fashionpedia training run exists publicly** (Roboflow has not released a checkpoint; the Hugging Face `yainage90/fashion-object-detection` model uses a different, 7-class taxonomy: `bag, bottom, dress, hat, shoes, outer, top`). https://huggingface.co/yainage90/fashion-object-detection
- **For internal data, the project should generate its own confusion matrix.** The `MLDiagnosticsStore` already records `modelClassRaw`. Add a query that bins predictions by user-corrected ground truth and you get the pairwise confusion you need. The dogfood failures (sneakers→boots, jeans→shorts, sunglasses→hat, belt→hat) are exactly the cells that confusion matrix should highlight.

---

## 6. Recommendations for Wardrobe Re-Do

### 6.1. Accept that the trained model can't distinguish everything

The 33-class model emits unambiguous category-level labels. For 8 classes (`shorts, skirt, boot, sandal, glasses, belt, watch, bracelet, earring, necklace, bag_wallet, sweater, cardigan, scarf`) the subcategory mapping is direct and reliable. For everything else (~half the trained vocabulary) the right answer is "category-level commit, subcategory-level deferred to user." The current code's approach of returning `nil` from `fromFashionpediaClass` for ambiguous classes is **correct** and should not be changed.

### 6.2. Fix the "Belt → Hat" / "Sunglasses → Hat" bug

This is **NOT a mapping fix** — both `belt` and `glasses` are correctly mapped. The bug is in one of:

(a) **Insufficient logging.** Add a single debug line in `applyPrefill` recording `(rawClass, predictedCategory, categoryConfidence, predictedSubcategory)`. Run dogfood. Find out which path the failing items take.

(b) **Category confidence threshold too aggressive.** If `predictedCategoryConfidence` for accessories is consistently below 0.80, `category` falls back to `.top`, and the entire accessory-rescue branch never runs. Lower the per-category threshold for `.accessory` (or remove the threshold entirely for high-objectness detections — DETR's combined "is this a valid detection AND class C" formulation makes the threshold double-count uncertainty).

(c) **`defaultSubcategory(.accessory) = .hat` is a UX trap.** When the user manually changes Category to "Accessories" via the picker (for any reason — including correcting an upstream mis-classification), the picker resets subcategory to `.hat`. They read "Hat" as the model's answer and report a bug. Recommend: either change the default to a more "neutral" accessory like `.bag`, OR (preferred) change the picker to show "Choose..." until the user picks one. This is a behavior fix, not a mapping fix.

### 6.3. Add the few label aliases that ARE wrong

These cases in `ClothingSubcategory.fromFashionpediaClass` are **dead code** (the model never emits these strings) and should either be (a) removed for clarity, or (b) kept and joined with the actual emitted strings:

| Current case in switch | Status | Recommendation |
|---|---|---|
| `"shirt"` | Dead — model emits `shirt_blouse` | Replace with `"shirt_blouse"` |
| `"t-shirt"` | Dead — model emits `top_t-shirt_sweatshirt` | Add `"top_t-shirt_sweatshirt"` mapping (returns nil — combo class) |
| `"sweatshirt"` | Dead — same as above | Same |
| `"sandal"` (without s) | OK | Keep |
| `"sandals"` | Dead — model emits `sandal` | Remove |
| `"glasses"` | Live — works | Keep |
| `"sunglasses"` | Dead — model emits `glasses` | Remove |
| `"hat"` | Live — works | Keep |
| `"cap"` | Dead — model never emits `cap` | Remove |
| `"earring"` | Live — works | Keep |
| `"earrings"` | Dead — model emits `earring` | Remove |

Same audit needed for `ClothingCategory.fromFashionpediaClass`:

| Dead case | Why dead |
|---|---|
| `"shirt"`, `"blouse"`, `"top"`, `"t-shirt"`, `"sweatshirt"` | Model emits `shirt_blouse` and `top_t-shirt_sweatshirt` |
| `"trousers"` | Model emits `pants` |
| `"tights"`, `"stockings"` | Model emits `tights_stockings` |
| `"gown"` | Model emits `dress` |
| `"romper"` | Not in trained class list at all |
| `"cap"`, `"head_covering"` | Model emits `hat` and `headband` |
| `"bow_tie"`, `"earrings"`, `"sandals"`, `"sunglasses"`, `"wallet"`, `"bag"`, `"purse"` | Model emits the singular/combo form |
| `"hood"`, `"hood_head_covering"` | Not in 33-class trained set |

The category-level switch DOES handle the model's actual emitted strings (`shirt_blouse`, `top_t-shirt_sweatshirt`, `tights_stockings`, `bag_wallet`) so it works at runtime — but the dead cases add ~30 lines of confusion when reading the code. Recommend a cleanup pass.

### 6.4. Confidence thresholds — set per-field, not global

Suggested values based on the model's actual behaviour:

| Field | Threshold | Rationale |
|---|---|---|
| Category (accessory) | 0.50 | Accessories are visually distinct; high threshold causes more "fall back to .top" bugs than it prevents. |
| Category (shoe / dress) | 0.80 | If the model is uncertain whether something is a dress or a top, the user-facing default is `.tshirt` which is wildly wrong for an ambiguous high-confidence shoe. |
| Subcategory | only when `fromFashionpediaClass` returns non-nil | Already correct — don't change. |
| Texture | 0.75 (current) | Keep. |
| Fit | 0.75 (current) | Keep. |

### 6.5. Where retraining would help (and where it wouldn't)

**Retrain CAN fix:**
- Jeans-detected-as-shorts: this is class boundary confusion that more pants-in-various-poses training data + class-balanced sampling would reduce.
- Headband / glove / ring / tie / hood / vest / jumpsuit / cape: add the corresponding `ClothingSubcategory` cases (`.headband`, `.gloves`, `.ring`, `.tie`, `.hood`, `.vest`, `.jumpsuit`, `.cape`) AND map the existing model labels to them. **No retraining needed for these — the model already emits the labels, the enum just doesn't have homes for them.**

**Retrain CANNOT fix without ontology change:**
- Sneaker vs boot vs heel: Fashionpedia category `shoe` is intrinsically ambiguous. Either (a) train an attribute head to predict shoe-type from the cropped mask, OR (b) use a separate dataset (UT Zappos50K, DeepFashion) that has the distinctions.
- Jeans vs chinos vs dress pants: same as above — Fashionpedia categories don't distinguish these. Need an attribute head or a domain-shift dataset.

### 6.6. Minimum-change action items

1. **Add debug logging** to `applyPrefill` so the next dogfood run captures which path each failing item takes (1 line of code).
2. **Lower confidence threshold for `.accessory`** detections (or remove threshold for >0.5 objectness) so glasses/belt detections aren't silently demoted to `.top`.
3. **Change `defaultSubcategory(.accessory)` away from `.hat`** to either `.bag` (more neutral) or a UI-level "Choose..." sentinel.
4. **Remove dead-code aliases** in `ClothingSubcategory.fromFashionpediaClass` and `ClothingCategory.fromFashionpediaClass`. The aliases that look correct but never fire are an active source of "the mapping looks fine, where's the bug?" wasted-time bugs.
5. **Add subcategory cases for the missed labels:** `.tie`, `.gloves`, `.ring`, `.headband`, `.vest`, `.jumpsuit`, `.cape`, `.hood`. Map them through. Each is a 4-line addition (case in enum, displayName, category, mapping in `fromFashionpediaClass`).
6. **For sneaker/boot disambiguation:** add a bbox-aspect-ratio post-processor in `MultiGarmentProposalService`. For `shoe`-class detections, if `bbox.height / bbox.width > 1.2` AND `bbox.minY < 0.5` of body region → bias towards `.boots`. Document the heuristic. This is a v1.x band-aid until Phase 6 ships shoe-attribute classification.
7. **For jeans/shorts disambiguation:** similar bbox-aspect post-processor. For `shorts`-class detections, if `bbox.height / bbox.width > 2.0` AND the image has a separate `shoe` detection clearly below the bbox (not adjacent) → flip to `pants`. Heuristic; document in source.

---

## 7. Sources

### Primary (authoritative dataset and model docs)

- [Fashionpedia project page](https://fashionpedia.github.io/home/) — Jia et al., 2020.
- [Fashionpedia ECCV 2020 paper](https://www.ecva.net/papers/eccv_2020/papers_ECCV/papers/123460307.pdf) — Jia, Shi, Sundaram, et al.
- [Fashionpedia ECCV 2020 supplementary material](https://www.ecva.net/papers/eccv_2020/papers_ECCV/papers/123460307-supp.pdf)
- [Fashionpedia GitHub (CVDF mirror)](https://github.com/cvdfoundation/fashionpedia) — annotation format docs.
- [Fashionpedia Python API (KMnP)](https://github.com/KMnP/fashionpedia-api) — wrapper for COCO-format access.
- [Hugging Face dataset mirror](https://huggingface.co/datasets/detection-datasets/fashionpedia) — convenient class index → name lookup; 46 ClassLabel definition.
- **`s3://ifashionist-dataset/annotations/instances_attributes_val2020.json`** — direct download verified during this research, source of the 46 categories + 294 attributes table above.

### RF-DETR

- [RF-DETR GitHub](https://github.com/roboflow/rf-detr) — Apache 2.0, ICLR 2026.
- [RF-DETR Segmentation model card](https://roboflow.com/model/rf-detr-segmentation)
- [Roboflow blog post on RF-DETR](https://blog.roboflow.com/rf-detr/)
- [RF-DETR releases page](https://github.com/roboflow/rf-detr/releases)
- [RF-DETR HF Space](https://huggingface.co/spaces/Roboflow/RF-DETR)
- [GitHub issue #51 (num_classes 1.4 quirk)](https://github.com/roboflow/rf-detr/issues/51)
- [GitHub issue #330 (1-indexed dataset class_embed neuron mismatch)](https://github.com/roboflow/rf-detr/issues/330)
- [GitHub issue #509 (head re-init incorrectly)](https://github.com/roboflow/rf-detr/issues/509)
- [GitHub PR #261 (warnings fix)](https://github.com/roboflow/rf-detr/pull/261)

### Related fashion-CV literature

- [DETR-Based Layered Clothing Segmentation, CVPRW 2023](https://openaccess.thecvf.com/content/CVPR2023W/CVFAD/papers/Tian_DETR-Based_Layered_Clothing_Segmentation_and_Fine-Grained_Attribute_Recognition_CVPRW_2023_paper.pdf) — Tian, Cao, Mok.
- [FashionFormer (ECCV 2022) GitHub](https://github.com/xushilin1/FashionFormer)
- [yainage90/fashion-object-detection on HF](https://huggingface.co/yainage90/fashion-object-detection) — 7-class fashion DETR fine-tune (Modanet+Fashionpedia merged).
- [UT Zappos50K dataset](https://vision.cs.utexas.edu/projects/finegrained/utzap50k/) — fine-grained shoe taxonomy reference.
- [Efficient Fine-Tuning for Fashion Object Detection, NIH PMC10346465](https://pmc.ncbi.nlm.nih.gov/articles/PMC10346465/) — Grounding DINO + fashion fine-tune.
- [Footwear segmentation/recommendation, ScienceDirect S187705092300354X](https://www.sciencedirect.com/science/article/pii/S187705092300354X)

### Project files referenced

- `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/WardrobeReDo/Models/Enums/ClothingSubcategory.swift`
- `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/WardrobeReDo/Models/Enums/ClothingCategory.swift`
- `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/WardrobeReDo/Services/Extraction/MultiGarmentProposalService.swift` (bundled label list, lines 148-158)
- `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/WardrobeReDo/ViewModels/AddItemViewModel.swift` (`applyPrefill`, lines 997-1096; `defaultSubcategory`, line 1103)
- `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/notebooks/training/2026-04-multi-garment.ipynb` (training notebook, source of the 33-class subset)
