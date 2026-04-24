# Fashionpedia → iOS enum attribute taxonomy

> **Status:** DRAFT FILLED — awaiting reviewer sign-off (Section 0 fork
> blocks Phase 2)
> **Phase:** 1 (see [../2026-04-19-auto-attribute-detection.md](../2026-04-19-auto-attribute-detection.md))
> **Owner:** trkngit (sign-off needed before Phase 2 dataset prep starts)

## Section 0 — Critical finding (read this first)

The full-train audit of Fashionpedia v2 (333,401 annotations across 294
attributes — see
[`fashionpedia_attribute_inventory.csv`](./fashionpedia_attribute_inventory.csv))
**does not contain attributes for the bulk fabric types**. The plan's
working assumption — that we'd train `TextureType` on Fashionpedia
attribute labels — is wrong.

What Fashionpedia v2 actually carries (by supercategory):

| supercategory | attr count | aggregate annotations | usable for? |
| ------------- | ---------- | --------------------- | ----------- |
| nickname | 152 | ~30k | subcategory hints + main-class refinement |
| silhouette | 25 | ~80k | **FitAttribute** (oversized/regular/tight/loose) |
| length | 15 | ~120k | subcategory hints (mini/midi/maxi/etc.) + cropped fit |
| waistline | 7 | ~60k | not modelled (skip) |
| neckline type | 25 | ~30k | subcategory hints (turtle, v-neck) |
| sleeve nicknames | 13 | ~50k | not modelled (skip) |
| opening type | 10 | ~45k | construction (skip) |
| collar / lapel nicknames | 17 | ~12k | not modelled (skip) |
| **non-textile material type** | 10 | ~70k | only fur+plastic+metal — **NO cotton/silk/wool/denim** |
| **leather** | 4 | 199 | leather variants (suede, shearling, crocodile, snakeskin) — **way below floor** |
| textile finishing techniques | 21 | ~75k | surface treatments (printed, ruched, quilted) — not fabric type |
| textile pattern | 17 | ~75k | print patterns (stripe, floral, plaid) — not fabric type |
| animal | 6 | ~600 | animal prints — not fabric type |

**Net effect on `TextureType`:** of the 15 enum cases, only **2** have
recoverable signal from Fashionpedia attributes:

- `leather` — fold {suede, shearling, crocodile, snakeskin} = 199 anns
  combined. **Below the 200/class floor**, requires balanced sampling
  + documented exception.
- `velvet` (maybe — quilted finishing texture is closest, but it's
  surface treatment not material) — ~234 anns of "quilted" exists but
  it's **not the same attribute**.

The remaining **13 TextureType cases** (cotton, silk, denim, wool,
linen, knit, synthetic, satin, chiffon, tweed, corduroy, nylon, suede)
have **zero direct labels** in Fashionpedia's attribute set.

`FitAttribute` is **mostly recoverable** — silhouette + length attributes
cover 5 of 6 cases (oversized, relaxed, regular, slim, cropped).
Structured has no direct signal.

`ClothingSubcategory` hints from length + neckline are usable for ~7
existing iOS cases.

### Three forks (pick one before Phase 2 starts)

#### Option A — Narrow vocabulary, ship what's recoverable

Train two heads on what Fashionpedia actually labels:
- `TextureType`: train just `leather` (with a documented sparsity
  exception); leave the other 13 cases as "user must select."
- `FitAttribute`: train all 5 recoverable cases; structured stays
  user-only.
- `ClothingSubcategory`: refine 7 cases via length + neckline rules.

**Pros:** stays on schedule, no new dataset hunt, Fashionpedia pipeline
is already production-tested. Honest about model limits — sparkle only
fires for fields we actually predicted, so users don't see misleading
auto-fills.
**Cons:** 13 of 15 textures still require user input. The "AI pre-fills
texture" promise in the original user request is mostly broken.

#### Option B — Pivot to a richer dataset for textures

Keep Fashionpedia for fit + subcategory; add a **second** dataset for
textures. Candidates:
- **DeepFashion-MultiModal** — has `fabric` annotations across cotton,
  denim, leather, wool, silk, polyester, knit, etc. ~50k images.
  Permissively licensed (CC BY-NC 4.0 — non-commercial; we'd need to
  check our license stance).
- **Fashion-MNIST-Garment-Material** (smaller research dataset, ~10k).
- **iMaterialist Fashion 2018** — has rich material attrs but the
  challenge dataset is on Kaggle and licensing is unclear.

**Pros:** restores the "AI texture pre-fill" promise, full TextureType
vocabulary trainable.
**Cons:** dataset hunt + licensing review (1–2 days), second training
pipeline (Phase 3 doubles in scope), domain-mismatch risk between
DeepFashion crops and our flat-lay/me-wearing photos.

#### Option C — Drop texture from auto-pre-fill v1

Skip TextureType entirely for v1. Ship category + fit + seasons +
occasions auto-pre-fill (everything but texture). Plan a v1.1 that
revisits texture via Option B once we have user-correction data showing
which textures users actually pick most.

**Pros:** ships the largest validated subset of the original ask. Puts
the texture decision behind real user signal instead of guessing at a
dataset.
**Cons:** the texture promise is fully deferred; users still see the
texture picker but it stays unfilled.

### Recommendation

**Option C** for v1, then revisit with Option B in v1.1 once dogfood
data tells us which textures matter. Rationale:
- Avoids a 1-2 week dataset-licensing detour during a release window.
- The Fashionpedia-only Option A would ship a sparkle that fires for
  exactly one texture (leather) — feels broken to users.
- Option B's dataset mismatch (DeepFashion runway shots vs our
  flat-lay/wearing photos) is a real accuracy risk that's hard to
  pre-empt without a dogfood run.

Sections 6 and 7 below are filled in **assuming Option C**. If you pick
A or B I'll regenerate Section 6 with the appropriate scope.

---

## Section 1 — iOS enum cases (source of truth)

Keep this list synced with the Swift enums if the codebase changes. Drift
is caught by Phase 0's ViewModel tests and Phase 5's exhaustiveness tests.

### TextureType (15 cases)

| rawValue | display | visualWeight | formalitySmoothness |
| -------- | ------- | ------------ | ------------------- |
| cotton | Cotton | medium | 5.0 |
| silk | Silk | light | 9.0 |
| denim | Denim | heavy | 3.0 |
| leather | Leather | heavy | 6.0 |
| suede | Suede | heavy | 6.0 |
| wool | Wool | heavy | 7.0 |
| linen | Linen | medium | 5.0 |
| knit | Knit | heavy | 4.0 |
| synthetic | Synthetic | medium | 4.0 |
| velvet | Velvet | heavy | 4.0 |
| satin | Satin | light | 9.0 |
| chiffon | Chiffon | light | 8.0 |
| tweed | Tweed | heavy | 7.0 |
| corduroy | Corduroy | heavy | 3.0 |
| nylon | Nylon | light | 4.0 |

### FitAttribute (6 cases)

`oversized`, `relaxed`, `regular`, `slim`, `structured`, `cropped`

### ClothingSubcategory (relevant cases for Phase 1 scope)

`tshirt`, `buttonDown`, `tankTop`, `cropTop`, `turtleneck`, `vneck`,
`hoodie`, `sweater`, `cardigan`, `blazer`, `jeans`, `sweatpants`,
`leggings`, `chinos`, `shorts`, `skirt`, `midiSkirt`, `miniSkirt`,
`maxiDress`, `miniDress`, `midiDress`, `dress`, `coat`, `jacket`,
`leatherJacket`, `denim_jacket`, `puffer`, `sneakers`, `boots`,
`sandal`, `dressShoes`, `heels`.

(See [WardrobeReDo/Models/Enums/ClothingSubcategory.swift](../../../WardrobeReDo/Models/Enums/ClothingSubcategory.swift)
for the full enumeration.)

## Section 2 — Texture candidate mapping (DEFUNCT under Option C)

Original draft (kept for archaeology). Replaced by Section 0's finding.

The plan assumed cotton/silk/wool would be Fashionpedia attributes;
they're not. Section 6 reflects the actual mapping.

## Section 3 — Fit candidate mapping (UPDATED)

Final mappings (Option-C-compatible — these are correct regardless of
the texture fork):

| ios_enum_case | Fashionpedia attribute | attr_id | global_count | confidence | notes |
| ------------- | ---------------------- | ------- | ------------ | ---------- | ----- |
| `oversized` | oversized | 138 | 670 | MEDIUM | sparse but direct match |
| `relaxed` | loose (fit) | 137 | 4,990 | HIGH | `loose` = our `relaxed` |
| `regular` | regular (fit) | 136 | 24,669 | HIGH | dominant class |
| `slim` | tight (fit) | 135 | 13,473 | HIGH | `tight` ≈ `slim` for our purposes |
| `cropped` | above-the-hip (length) | 146 | 17,444 | MEDIUM | refines tops only; not a true "fit" but the closest signal Fashionpedia has |
| `structured` | _(no source)_ | — | 0 | — | gap — see Section 7 |

## Section 4 — Subcategory hint mapping (UPDATED)

Refinements that `ClothingSubcategory.fromFashionpediaClass` can layer
on top of the main-class detection. Used by Phase 6 to narrow ambiguous
class assignments.

| ios_enum_case | Fashionpedia attr (id) | confidence | notes |
| ------------- | ---------------------- | ---------- | ----- |
| `miniSkirt` | mini (length, 149) AND main_class=skirt | HIGH | length attr alone is ambiguous; gate on main class |
| `midiSkirt` | midi (length, 153) AND main_class=skirt | HIGH | |
| `maxiDress` | maxi (length, 154) AND main_class=dress | HIGH | |
| `miniDress` | mini (length, 149) AND main_class=dress | HIGH | |
| `midiDress` | midi (length, 153) AND main_class=dress | HIGH | |
| `turtleneck` | turtle (neck, 198) | HIGH | 651 anns |
| `vneck` | v-neck (183) | HIGH | 3,130 anns |
| `cropTop` | crop (top) (8) AND main_class=top | HIGH | 1,105 anns; explicit nickname |
| `hoodie` | hoodie (16) AND main_class=top | HIGH | 414 anns |
| `blazer` | blazer (17) AND main_class=jacket | HIGH | 2,900 anns |
| `jeans` | jeans (36) AND main_class=pants | HIGH | 3,764 anns; also implies denim texture (Option B path) |
| `leggings` | leggings (38) AND main_class=pants | HIGH | 1,787 anns |

These are **NOT trained** in Phase 3 — they're pure rules layered into
the existing `ClothingSubcategory.fromFashionpediaClass` helper. Phase
6 wires them in.

## Section 5 — Categorical exclusions

Fashionpedia attributes that we explicitly **do not map** and should
ignore in `prepare_attribute_dataset.py`:

- All `nickname` collar / lapel / sleeve / pocket attributes — too
  fine-grained for v1 (no iOS surface)
- `opening type` (zip-up, fly, lace-up, etc.) — construction detail
- `waistline` (high/normal/low/etc.) — out of v1 scope
- `textile finishing techniques` (printed, ruched, quilted, etc.) —
  surface treatments, not material; existing color-extraction pipeline
  already covers prints
- `textile pattern` (stripe, floral, plaid, etc.) — pattern, not texture
- `animal` (leopard, zebra, etc.) — animal print pattern, not material
- `non-textile material type` except as flagged in Section 7

## Section 6 — Reviewer worksheet (FILLED, Option C scope)

Format: `attr_id | attr_name | global_count | decision | notes`.

### 6a — Mapped to FitAttribute (5 attrs)

| attr_id | attr_name | global_count | decision | notes |
| ------- | --------- | ------------ | -------- | ----- |
| 135 | tight (fit) | 13,473 | `FitAttribute.slim` | fold "tight" → "slim" |
| 136 | regular (fit) | 24,669 | `FitAttribute.regular` | direct |
| 137 | loose (fit) | 4,990 | `FitAttribute.relaxed` | fold "loose" → "relaxed" |
| 138 | oversized | 670 | `FitAttribute.oversized` | direct |
| 146 | above-the-hip (length) | 17,444 | `FitAttribute.cropped` | tops only — gate on main_class ∈ {top, t-shirt, sweatshirt, jacket, shirt-blouse}; for non-tops this attr is meaningless |

### 6b — Mapped to ClothingSubcategory hints (12 attrs)

Used by Phase 6 rules layer, NOT a Phase 3 training target. Listed here
for traceability.

| attr_id | attr_name | global_count | hint_target |
| ------- | --------- | ------------ | ----------- |
| 8 | crop (top) | 1,105 | `cropTop` |
| 16 | hoodie | 414 | `hoodie` |
| 17 | blazer | 2,900 | `blazer` |
| 36 | jeans | 3,764 | `jeans` |
| 38 | leggings | 1,787 | `leggings` |
| 149 | mini (length) | 9,545 | `miniSkirt` / `miniDress` (gate on main class) |
| 153 | midi | 2,266 | `midiSkirt` / `midiDress` |
| 154 | maxi (length) | 9,376 | `maxiDress` |
| 183 | v-neck | 3,130 | `vneck` |
| 198 | turtle (neck) | 651 | `turtleneck` |
| 50 | short (shorts) | 1,575 | `shorts` (already covered by main class) |
| 65 | skater (skirt) | 358 | hint toward `aLineSkirt` if present in enum, else skip |

### 6c — TextureType mapping (Option C: NONE trained)

Under Option C, we do not train a TextureType head. The Fashionpedia
attributes that *could* feed a leather-only head if we picked Option A
are listed in Section 7 as gaps for traceability.

### 6d — Skipped (everything else, ~270 attrs)

All attributes in supercategories `opening type`, `waistline`,
`textile finishing, manufacturing techniques`, `textile pattern`,
`animal`, `non-textile material type` (except fur/leather variants
listed in Section 7), `collar/lapel/pocket/sleeve nicknames`, and the
unused `length` attrs (above-the-knee, knee, below-the-knee,
sleeveless, short-length, elbow, three-quarter, wrist) are
**dropped from training**. Section 5 lists the rationale.

Per-attribute callouts not worth including in 6a/6b:
- `225 single breasted` (12,175) — opening type, skipped
- `229 zip-up` (16,859) — opening type, skipped
- `230 fly (opening)` (9,030) — opening type, skipped
- `295 no non-textile material` (65,854) — meta-label, no signal
- `301 printed` (8,028) — pattern, skipped (color pipeline covers)
- `316 no special manufacturing technique` (38,349) — meta-label
- `317 plain (pattern)` (58,468) — meta-label

## Section 7 — Gaps surfaced during review

Each row: `gap target | reason | decision`.

| target | source attr (if any) | gap reason | decision under Option C |
| ------ | -------------------- | ---------- | ----------------------- |
| `TextureType.cotton` | _(none)_ | Fashionpedia has no cotton attribute; main fabric is implicit in main classes | **defer to v1.1**; user fills picker |
| `TextureType.silk` | _(none)_ | same | defer |
| `TextureType.denim` | implicit via attr 36 (jeans) for pants only | only pants get an inferred denim signal; jackets/skirts can't be inferred | defer; rules engine could imply denim for jeans subcategory only (low value) |
| `TextureType.leather` | attrs 290-293 (suede, shearling, crocodile, snakeskin) — 199 anns combined | below 200/class floor; "plain leather" has no atomic attr | defer (Option A would train this with sparsity exception) |
| `TextureType.suede` | attr 290 suede (84) | 84 anns is far below floor | defer |
| `TextureType.wool` | _(none)_ | same as cotton | defer |
| `TextureType.linen` | _(none)_ | same | defer |
| `TextureType.knit` | implicit via attr-based main-class "sweater" / "cardigan" (no atomic attr) | knit is a class-level signal not an attribute-level one | rules engine could imply knit for sweater/cardigan subcategory (Phase 5 follow-up) |
| `TextureType.synthetic` | partial: attr 281 plastic (3,108) is closest | "plastic" is non-textile, not the same as polyester/synthetic textile | defer |
| `TextureType.velvet` | _(none)_ | not in Fashionpedia attribute set | defer |
| `TextureType.satin` | _(none)_ | same | defer |
| `TextureType.chiffon` | _(none)_ | same | defer |
| `TextureType.tweed` | _(none)_ | same | defer |
| `TextureType.corduroy` | _(none)_ | same | defer |
| `TextureType.nylon` | _(none)_ | same | defer |
| `FitAttribute.structured` | _(none)_ | no direct silhouette attr; could be implied by main_class ∈ {blazer, suit jacket} | rules engine implies structured for blazer/suit subcategory — Phase 5 follow-up |
| iOS-side `fur` enum case | attr 289 fur (730) | no `TextureType.fur` case — Fashionpedia signal exists but no place to put it | **propose iOS enum extension** (low priority, defer to v1.1) |

## Verification (Option C)

- Texture-mapped rows: 0 / 15 enum cases (DOCUMENTED — Section 0
  finding accepted via Option C)
- Fit-mapped rows: 5 / 6 enum cases (above the ≥4 floor)
- Per-class floor: every mapped fit case has ≥670 source annotations
  (above the 200 floor)
- Subcategory hints: 12 attrs feeding 8 enum cases via the rules layer

Phase 2 prep can proceed with **fit-only training**.

## Section 8 — Implementation impact (Option C)

If you sign off on Option C:

1. **Phase 2** (`prepare_attribute_dataset.py`):
   - Single label head: `fit_label` (5 classes + a "regular" default for
     instances that don't carry any of the 5 fit attrs).
   - Drop the texture head entirely.
   - Filter: keep annotations where the bbox class is in the v1
     wardrobe scope (top, pants, dress, jacket, coat, skirt, shorts) AND
     at least one of attrs {135, 136, 137, 138, 146} is present.
   - Estimated dataset size: ~30k crops (down from ~50k).

2. **Phase 3** (`train_attributes.py`):
   - MobileNetV3-Small with **single 5-class head** (not multi-head).
   - Same training schedule.
   - Target: ≥75% top-1 on held-out val (achievable given the strong
     class imbalance favouring `regular`).

3. **Phase 4** (`AttributeClassifierService`):
   - `predict(crop:)` returns `(fit: FitAttribute?, fitConf: Float)`
     — texture stays nil.
   - Existing iOS code already tolerates nil texture (Phase 0 wiring),
     so no further iOS changes.
   - mlpackage size budget halved (~2 MB).

4. **Phase 5** (`AttributeRulesEngine`): no change. The rules layer
   already handles seasons + occasions deterministically; texture-derived
   rules degrade gracefully when texture is nil.

5. **Phase 8** (sparkle UX): no change. Sparkle fires only for fields
   with snapshot entries; texture without a prediction stays unsparked,
   which is the correct UX signal.

6. **iOS-side documentation update needed:** the original Phase 0 plan
   talked about texture pre-fill. Update the per-phase status notes in
   the parent plan to flag Texture as deferred under Option C.

## Next action

Reviewer (trkngit): pick Option A / B / C and reply on this thread. I
will then:
- regenerate Section 6 if A or B is chosen
- proceed to Phase 2 prep script writing if C is chosen (default
  recommendation)
