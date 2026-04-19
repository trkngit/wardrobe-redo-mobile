# Season & Occasion rules table

> **Status:** DRAFT — reviewer sign-off needed before Phase 5 Swift ships
> **Phase:** 5 (see [../2026-04-19-auto-attribute-detection.md](../2026-04-19-auto-attribute-detection.md))

## Purpose

`AttributeRulesEngine.derive(category, subcategory, texture)` is the
deterministic function that turns the attribute classifier's output into
a pre-fill for the `Set<Season>` and `Set<Occasion>` pickers on the Add
Item form.

**Hard invariant:** both return sets are always non-empty. An empty
predicted set falls back to `Season.allCases` / `[.casual]` so the
picker never lands on the user with zero selections.

## How this table becomes code

Each rule below compiles to one `case` in the pattern-match blocks in
[`RulesTable.swift`](../../../WardrobeReDo/Services/AttributeRules/RulesTable.swift).
Precedence is **top-to-bottom**: the first matching rule wins. If no
rule matches, the fallback is `Season.allCases` / `[.casual]`.

Scoping conventions in the table:

- **Category = `*`** — applies to every category.
- **Subcategory = `*`** — applies to every subcategory under the named
  category.
- **Texture = `*`** — applies regardless of texture (nil or any value).
- **Texture = `(nil)`** — applies only when no texture was predicted
  confidently; e.g. "if we know nothing about the fabric, fall back to
  the category's baseline seasons."

## Season rules

### Footwear (category = `shoe`)

| # | category | subcategory | texture | seasons | rationale |
| - | -------- | ----------- | ------- | ------- | --------- |
| 1 | shoe | sandals | * | `[.summer]` | open-toe, hot-weather only |
| 2 | shoe | boots | wool | `[.fall, .winter]` | lined / heavyweight boots |
| 3 | shoe | boots | leather, suede | `[.fall, .winter]` | dress boots, leather boots |
| 4 | shoe | boots | * | `[.fall, .winter]` | closed, insulating silhouette |
| 5 | shoe | chelseaBoots | * | `[.fall, .winter]` | |
| 6 | shoe | heels, flats, loafers, oxford, derby, balletFlat, dressShoes | * | `Season.allCases` | dress footwear worn year-round indoors |
| 7 | shoe | sneakers, sneakerLow, sneakerHigh, highTops, designerSneakers, runningShoe | * | `[.spring, .summer, .fall]` | exposed foot in cold weather is unusual |

### Outerwear (category = `outerwear`)

| # | category | subcategory | texture | seasons | rationale |
| - | -------- | ----------- | ------- | ------- | --------- |
| 10 | outerwear | puffer, parka, winterCoat, overcoat | * | `[.winter]` | cold-weather only |
| 11 | outerwear | leatherJacket, suitJacket, blazer | * | `[.spring, .fall]` | transitional weight |
| 12 | outerwear | denimJacket, bomber, varsityJacket, shirtJacket, windbreaker | * | `[.spring, .fall]` | |
| 13 | outerwear | trench | * | `[.spring, .fall]` | classic shoulder-season coat |
| 14 | outerwear | cardigan | wool, knit | `[.fall, .winter]` | |
| 15 | outerwear | cardigan | cotton, linen, silk | `[.spring, .fall]` | lightweight layering |
| 16 | outerwear | cardigan | * | `[.spring, .fall]` | default for cardigans |
| 17 | outerwear | * | wool, tweed | `[.fall, .winter]` | any wool/tweed outerwear |
| 18 | outerwear | * | leather, suede | `[.fall, .winter]` | |
| 19 | outerwear | * | * | `[.spring, .fall, .winter]` | outerwear defaults exclude summer |

### Dresses (category = `dress`)

| # | category | subcategory | texture | seasons | rationale |
| - | -------- | ----------- | ------- | ------- | --------- |
| 20 | dress | sundress, maxiDress, miniDress, wrapDress | * | `[.spring, .summer]` | hot-weather silhouettes |
| 21 | dress | * | silk, chiffon, satin, linen, cotton | `[.spring, .summer]` | lightweight fabrics |
| 22 | dress | * | wool, tweed, velvet, knit | `[.fall, .winter]` | heavier fabrics |
| 23 | dress | * | leather, suede | `[.fall, .winter]` | |
| 24 | dress | cocktailDress, sheathDress | * | `Season.allCases` | indoor-event-driven |
| 25 | dress | * | * | `Season.allCases` | dress default: all seasons |

### Tops (category = `top`)

| # | category | subcategory | texture | seasons | rationale |
| - | -------- | ----------- | ------- | ------- | --------- |
| 30 | top | tankTop, tank, camisole, cropTop | * | `[.spring, .summer]` | |
| 31 | top | sweatshirt, sweater, knitSweater, hoodie, turtleneck | * | `[.fall, .winter]` | heavyweight / insulating |
| 32 | top | * | wool, tweed, velvet, knit | `[.fall, .winter]` | |
| 33 | top | * | linen, silk, chiffon | `[.spring, .summer]` | |
| 34 | top | * | * | `Season.allCases` | tops default: all seasons |

### Bottoms (category = `bottom`)

| # | category | subcategory | texture | seasons | rationale |
| - | -------- | ----------- | ------- | ------- | --------- |
| 40 | bottom | shorts, miniSkirt | * | `[.spring, .summer]` | |
| 41 | bottom | leggings, joggers | * | `Season.allCases` | athleisure worn year-round |
| 42 | bottom | * | linen, silk, chiffon | `[.spring, .summer]` | |
| 43 | bottom | * | wool, tweed, corduroy, velvet | `[.fall, .winter]` | |
| 44 | bottom | * | leather, suede | `[.fall, .winter]` | |
| 45 | bottom | * | denim | `Season.allCases` | wear-anywhere staple |
| 46 | bottom | * | * | `Season.allCases` | default: all seasons |

### Accessories (category = `accessory`)

| # | category | subcategory | texture | seasons | rationale |
| - | -------- | ----------- | ------- | ------- | --------- |
| 50 | accessory | scarf, beanie | * | `[.fall, .winter]` | cold-weather only |
| 51 | accessory | sunglasses | * | `[.spring, .summer]` | |
| 52 | accessory | baseballCap, hat, fedoraHat | * | `[.spring, .summer, .fall]` | sun-facing |
| 53 | accessory | * | * | `Season.allCases` | default: all seasons |

## Occasion rules

Occasion is more about subcategory + texture "weight" than season:
formal fabrics (silk/satin/wool) + dress shoes → work/formal; heavy-duty
athletic fabrics (nylon/synthetic) → athletic; at-home silhouettes
(joggers, hoodies, robes-style loungewear) → lounge.

### Formal / work skew (dress fabrics)

| # | category | subcategory | texture | occasions | rationale |
| - | -------- | ----------- | ------- | --------- | --------- |
| 100 | top | * | silk, satin, chiffon | `[.work, .date, .formal]` | dressy fabrics |
| 101 | bottom | dressPants, pencilSkirt | * | `[.work, .formal]` | |
| 102 | shoe | heels, dressShoes, oxford, derby, loafers | * | `[.work, .date, .formal]` | |
| 103 | outerwear | suitJacket, trench, overcoat | * | `[.work, .formal]` | |
| 104 | dress | cocktailDress, sheathDress | * | `[.work, .date, .formal]` | |
| 105 | top | * | wool, tweed | `[.casual, .work, .date]` | wool's acceptable at work |

### Athletic

| # | category | subcategory | texture | occasions | rationale |
| - | -------- | ----------- | ------- | --------- | --------- |
| 110 | bottom | joggers, leggings | * | `[.casual, .athletic, .lounge]` | |
| 111 | shoe | sneakers, sneakerLow, sneakerHigh, highTops, runningShoe, designerSneakers | * | `[.casual, .athletic]` | designer sneakers lose lounge |
| 112 | top | * | synthetic, nylon | `[.casual, .athletic]` | performance fabrics |

### Lounge

| # | category | subcategory | texture | occasions | rationale |
| - | -------- | ----------- | ------- | --------- | --------- |
| 120 | top | sweatshirt, hoodie | * | `[.casual, .athletic, .lounge]` | |
| 121 | bottom | joggers | * | `[.casual, .athletic, .lounge]` | duplicate of rule 110 — first-match wins |

### Casual defaults

| # | category | subcategory | texture | occasions | rationale |
| - | -------- | ----------- | ------- | --------- | --------- |
| 130 | top | tshirt, tankTop, tank, camisole, cropTop, graphicTee, henley, polo | * | `[.casual]` | |
| 131 | bottom | jeans, shorts, cargo, chinos | * | `[.casual, .date]` | jeans date-acceptable |
| 132 | shoe | sandals | * | `[.casual]` | sandals feel casual-only |
| 133 | outerwear | denimJacket, bomber, varsityJacket, shirtJacket | * | `[.casual, .date]` | |
| 134 | dress | sundress, casualDress | * | `[.casual, .date]` | |
| 135 | accessory | * | * | `[.casual, .work, .date, .formal]` | accessories don't narrow occasion |

### Fallbacks (last resort)

| # | category | subcategory | texture | occasions | rationale |
| - | -------- | ----------- | ------- | --------- | --------- |
| 199 | * | * | * | `[.casual]` | matches the non-empty invariant |

## Invariant tests (Phase 5 test suite must verify)

1. **Non-empty return sets** — for every `(ClothingCategory,
   ClothingSubcategory, TextureType?)` triple, both returned sets are
   non-empty.
2. **First-match wins** — known canonical cases always resolve:
   - `(shoe, sandals, cotton) → seasons=[.summer]` (rule 1 wins).
   - `(outerwear, puffer, nylon) → seasons=[.winter]` (rule 10 wins).
   - `(top, tshirt, cotton) → seasons=allCases, occasions=[.casual]`
     (rule 34 + rule 130 — rule 130 comes before rule 135 for occasion).
   - `(shoe, dressShoes, leather) → occasions includes .work & .formal`
     (rule 102).
3. **Exhaustiveness** — every `TextureType` case appears in at least one
   rule clause (property-based test driven by `TextureType.allCases`).

## Next action

1. Reviewer: amend rules they disagree with — flag row numbers.
2. Translate the approved table into
   [`RulesTable.swift`](../../../WardrobeReDo/Services/AttributeRules/RulesTable.swift) `switch` cases.
3. Tests land alongside.
