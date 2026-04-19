# Fashionpedia → iOS enum attribute taxonomy

> **Status:** DRAFT — awaiting audit CSV
> **Phase:** 1 (see [../2026-04-19-auto-attribute-detection.md](../2026-04-19-auto-attribute-detection.md))
> **Owner:** reviewer needed (user sign-off expected before Phase 2 dataset prep starts)

## Purpose

Decide, for every Fashionpedia fine-grained attribute that
`audit_fashionpedia_attributes.py` surfaces, whether it maps to:

- A case on `TextureType` (`StyleEnums.swift:3`)
- A case on `FitAttribute` (`StyleEnums.swift:32`)
- A case on `ClothingSubcategory` (`ClothingSubcategory.swift:17`)
- **Nothing** (dropped — out of v1 scope)

The output of this doc is the lookup table consumed by
`prepare_attribute_dataset.py` (Phase 2) to label each cropped garment box
with `(texture_label, fit_label)` training targets.

## How to use this file

1. Run [`audit_fashionpedia_attributes.py`](../../../notebooks/training/scripts/audit_fashionpedia_attributes.py)
   against `instances_attributes_train2020.json`. This produces
   [`fashionpedia_attribute_inventory.csv`](./fashionpedia_attribute_inventory.csv).
2. Open the CSV alongside this file. Walk each row top-to-bottom.
3. For each row, fill in the decision in Section 6 below
   (`ios_enum_case`, `confidence_note`).
4. When a row's `coverage_note` reads `texture-candidate` or
   `fit-candidate` but no iOS enum case fits, mark it `ios_enum_case =
   "(gap)"` and add a row to Section 7.
5. Commit the filled-in doc + CSV. Phase 2 can start.

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

## Section 2 — Texture candidate mapping (DRAFT)

> This is a **best-guess first pass** before the audit CSV lands. Every
> row here needs reviewer validation — particularly the Fashionpedia
> names, which I haven't confirmed against the live JSON yet.

Pattern: a row is worth mapping if the Fashionpedia attribute has ≥500
co-occurrences in `fashionpedia_attribute_inventory.csv`. Below that
threshold, class imbalance on the Phase 3 classifier will be brutal.

| ios_enum_case | likely Fashionpedia attribute name(s) | confidence | notes |
| ------------- | ------------------------------------- | ---------- | ----- |
| `cotton` | `cotton`, maybe `jersey (fabric)` | HIGH | biggest single material bucket, expect ≥10k annotations |
| `silk` | `silk` | HIGH | |
| `denim` | `denim` | HIGH | one-to-one; should dominate the `pants`+`skirt` categories |
| `leather` | `leather`, maybe `faux leather` → fold | HIGH | |
| `suede` | `suede` | MEDIUM | sparser than leather; watch class imbalance |
| `wool` | `wool` | HIGH | |
| `linen` | `linen` | MEDIUM | |
| `knit` | `knit`, `knitted fabric` | HIGH | heavy overlap with `sweater` category — use as reinforcement signal |
| `synthetic` | `polyester`, `rayon`, `viscose`, `acrylic`, `nylon (fold to nylon)` | LOW | grab-bag bucket; argmax may be unstable |
| `velvet` | `velvet` | MEDIUM | rare, may need oversampling |
| `satin` | `satin` | MEDIUM | |
| `chiffon` | `chiffon` | MEDIUM | |
| `tweed` | `tweed` | LOW | likely <500 annotations — candidate for the `corduroy`-style documented exception |
| `corduroy` | `corduroy` | LOW | same issue |
| `nylon` | `nylon` | MEDIUM | |

**Gaps to watch for (Section 7):**
- Patterns (stripes, plaid, floral) — not `TextureType` but might bleed into the pickers if the model latches onto them.
- Metallic / sequined / embroidered — no iOS case; drop.

## Section 3 — Fit candidate mapping (DRAFT)

| ios_enum_case | likely Fashionpedia attribute name(s) | confidence | notes |
| ------------- | ------------------------------------- | ---------- | ----- |
| `oversized` | `oversized (fit)`, maybe `loose (fit)` | MEDIUM | fold both if counts are low |
| `relaxed` | `loose (fit)`, `relaxed` | MEDIUM | overlap with `oversized` may cause the classifier to be uncertain between these two — consider merging for v1 |
| `regular` | `regular (fit)`, `normal fit` | HIGH | the default, expect dominant class |
| `slim` | `slim (fit)`, `fitted` | HIGH | |
| `structured` | `structured`, `tailored` | MEDIUM | primarily blazers/suit jackets |
| `cropped` | `cropped`, `crop top` (silhouette) | MEDIUM | overlaps with `cropTop` subcategory — prefer the subcategory signal when it fires |

**Gaps:**
- `asymmetrical`, `high-low` — silhouettes we don't model; drop.
- `maxi`, `midi`, `mini` (length) — these are subcategory signals, not fit. Map them in Section 4.

## Section 4 — Subcategory hint mapping (DRAFT)

`ClothingSubcategory.fromFashionpediaClass` already handles the obvious
class-level mappings. Fashionpedia's ATTRIBUTE-level length/neckline hints
can refine these further. This section exists so Phase 6 has a future
lever — Phase 1 doesn't need to commit anything here.

| ios_enum_case | fashionpedia attribute hint | confidence | notes |
| ------------- | --------------------------- | ---------- | ----- |
| `midiSkirt` | length: midi + class: skirt | HIGH | |
| `miniSkirt` | length: mini + class: skirt | HIGH | |
| `maxiDress` | length: maxi + class: dress | HIGH | |
| `miniDress` | length: mini + class: dress | HIGH | |
| `midiDress` | length: midi + class: dress | HIGH | |
| `turtleneck` | neckline: turtle + class: top | MEDIUM | |
| `vneck` | neckline: v-neck + class: top | MEDIUM | |

Out of scope for Phase 1 commit — captured here so the user can scope
Phase 6 ambitiously without re-opening the taxonomy file.

## Section 5 — Categorical exclusions

Fashionpedia attributes that we explicitly **do not map** and should
ignore in `prepare_attribute_dataset.py`:

- Construction details: `zipper`, `buttons`, `ties`, `drawstring`
- Decoration: `embroidered`, `sequined`, `beaded`, `fringed`
- Print / color (pattern): `striped`, `floral`, `plaid`, `polka dot` —
  the app already runs a separate color-extraction pipeline
- Hood / collar / cuff variants — too fine-grained for v1
- Material subtypes we don't surface: `jacquard`, `crochet`, `mesh`
  (unless Section 7 flags one)

## Section 6 — Reviewer worksheet (fill in after running audit)

Open `fashionpedia_attribute_inventory.csv` and mirror its rows here,
then fill in the decision column. Format (tab-separated, paste-friendly):

```
attr_id    attr_name    global_count    ios_enum_case    confidence_note
```

Examples:
```
42         cotton       12450           TextureType.cotton      HIGH — dominant material
87         floral       8100            (skip — pattern not texture)    see Section 5
201        oversized    5600            FitAttribute.oversized  HIGH
```

## Section 7 — Gaps surfaced during review

Rows the reviewer flagged as `ios_enum_case = "(gap)"`. Each entry gets
a one-line decision: drop, defer to v1.1, or request an iOS enum extension.

| attr_name | global_count | gap type | decision |
| --------- | ------------ | -------- | -------- |
| _(to be filled in)_ | | | |

## Verification

After Sections 6 and 7 are filled in:

- Count texture-mapped rows — target ≥10 distinct `TextureType` cases
  covered (at least 10 of the 15 enum cases have a Fashionpedia source).
- Count fit-mapped rows — target ≥4 distinct `FitAttribute` cases covered.
- Per-class floor: every mapped iOS enum case must have ≥200 source
  annotations (below that, Phase 3 needs balanced-sampling + documented
  exception in `ATTRIBUTE_TRAINING_PLAN.md`).

Once verified, Phase 2 starts.

## Next action

1. Run `audit_fashionpedia_attributes.py` on the pod (where the annotation
   JSON already lives) or locally after downloading the file.
2. Paste the CSV into `fashionpedia_attribute_inventory.csv` alongside
   this doc.
3. Walk the rows top-down, completing Section 6.
4. Get user sign-off, then unblock Phase 2.
