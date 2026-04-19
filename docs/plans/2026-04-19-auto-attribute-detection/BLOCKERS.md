# Auto-Attribute Detection — Blockers & Gaps Register

> **Context:** Compiled 2026-04-19 right after the user signed off on
> **Option C** (defer TextureType to v1.1; ship Category + Fit + Seasons
> + Occasions in v1). This file lists every blocker, gap, and future
> follow-up surfaced during the pre-Phase 2 audit so nothing gets lost
> between sessions.
>
> **Status convention:**
> - 🔴 **IMMEDIATE** — must be fixed with the Option C sign-off commit
>   (trivial copy/comment changes; not doing so risks misleading
>   maintainers)
> - 🟡 **PHASE 2 DESIGN** — must be handled *in* the preparer script;
>   not fixing means training on wrong-scope data
> - 🟢 **DEFERRED** — non-blocking; capture now, fix in v1.1 or when the
>   right phase arrives

---

## 🔴 IMMEDIATE (fix now)

### I-1 — Dev Menu toggle copy mentions texture

- **File:** [WardrobeReDo/Views/Settings/DeveloperMenuView.swift:61](../../../WardrobeReDo/Views/Settings/DeveloperMenuView.swift)
- **Problem:** Current copy "Pre-select category, texture, fit, seasons,
  and occasions after capture." sets the user up to expect texture
  pre-fill. Under Option C the texture picker will stay empty forever
  in v1, so the toggle's behavior won't match its description.
- **Fix:** Remove "texture," from the list and add a short note that
  texture is user-input until v1.1.
- **Size:** 1 line

### I-2 — AttributeClassifierService carries a dead texture head

- **File:** [WardrobeReDo/Services/Extraction/AttributeClassifierService.swift:155-159](../../../WardrobeReDo/Services/Extraction/AttributeClassifierService.swift)
- **Problem:** `textureLabels` (15 cases) and the decode-path texture
  branch assume a two-head mlpackage. Phase 3 under Option C will train
  a **single-head** fit classifier, so the exported mlpackage won't
  emit `texture_probs` at all. The existing decode is already
  nil-tolerant (`multiArray → argmaxSoftmax → (nil, 0.0)` → texture
  stays nil), so runtime behavior is correct — but a maintainer reading
  the file will reasonably conclude that texture IS being classified.
- **Fix:** Add a prominent comment header on `textureLabels` explaining
  the Option C dormancy + v1.1 reactivation path. Leave the code in
  place (easy v1.1 reinstatement once a texture dataset lands).
- **Size:** ~8 lines of comment

### I-3 — MaskProposal.predictedTexture doc comment is outdated

- **File:** [WardrobeReDo/Models/MaskProposal.swift:52-55](../../../WardrobeReDo/Models/MaskProposal.swift)
- **Problem:** Comment says "Nil until the attribute model ships (Phase
  3–4 of the auto-attribute-detection plan)". Under Option C it is nil
  permanently in v1. A future reader will think the field is pending
  wiring, not dormant by design.
- **Fix:** Replace the "nil until ships" wording with "nil in v1; v1.1
  revisits (see [ATTRIBUTE_TAXONOMY.md § Section 0](./ATTRIBUTE_TAXONOMY.md))".
- **Size:** 2 lines

---

## 🟡 PHASE 2 DESIGN (handle in preparer script)

These are blockers that only bite when we actually start cropping the
dataset. The `prepare_attribute_dataset.py` spec below is the fix for
each.

### P2-1 — `FitAttribute.cropped` leaks to non-tops without gating

- **Source of bug:** Fashionpedia attr **146 "above-the-hip (length)"**
  is the closest signal we have for `FitAttribute.cropped`. But
  Fashionpedia emits it on **dresses, skirts, and tops** — because
  "above-the-hip" is a hem-height label, not a fit label. A short dress
  gets tagged 146 and, if we don't gate, would be labeled
  `FitAttribute.cropped` in training.
- **Enforcement:** In the preparer, only emit `cropped` when the
  annotation's bbox category ∈ `{shirt-blouse, top-t-shirt-sweatshirt,
  sweater, cardigan, jacket, vest}`. For all other classes, **drop
  attr 146 silently** (it's irrelevant fit signal for dresses/skirts).
- **Test:** add a unit test on the preparer that asserts: "feed a
  dress annotation carrying attr 146 → resulting CSV row does NOT have
  `cropped`".

### P2-2 — Multi-attribute annotations need a tie-break

- **Source of bug:** A single Fashionpedia annotation can carry
  multiple attribute IDs. Most co-occurrences are harmless (e.g. fit +
  silhouette + length together = the full description). But we could
  see conflicting fit labels: `{135 tight, 136 regular}` or
  `{137 loose, 138 oversized}`. Manual annotation drift makes this
  <2% likely but not zero.
- **Decision:** **Drop ambiguous samples** (>1 fit attribute from
  {135, 136, 137, 138}). Cost: small (~1–2% of crops). Benefit: clean
  single-label training data. We can revisit with multi-label loss in
  v1.1 if the correction data shows fit accuracy is poor.
- **Exception:** attr 146 (cropped/length) is compatible with any of
  {135, 136, 137} since it labels a different axis. When both are
  present, prefer `cropped` (more specific label wins); otherwise use
  the explicit fit attr.

### P2-3 — 37:1 class imbalance (`regular` vs `oversized`)

- **Source of bug:** From the audit:
  - attr 136 regular (24,669 anns)
  - attr 135 tight/slim (13,473 anns)
  - attr 146 above-the-hip/cropped (17,444 anns, gated to tops only)
  - attr 137 loose/relaxed (4,990 anns)
  - attr 138 oversized (670 anns)

  Without intervention, a MobileNetV3-Small head trained on this will
  collapse to "always regular". The 670-ann `oversized` class is
  borderline trainable — needs balanced sampling.
- **Enforcement (preparer):** Emit class counts into `manifest.csv`
  metadata so Phase 3 can read them and apply either class-balanced
  loss (`WeightedRandomSampler`) or inverse-frequency softmax
  weighting.
- **Enforcement (training, Phase 3):** Use class-weighted CE loss with
  weights = `max_count / class_count` clamped to `[1, 10]`.

### P2-4 — Unlabelled annotations (majority of corpus)

- **Source of bug:** Most Fashionpedia annotations carry zero fit
  attributes — they were annotated with other supercategories
  (silhouette, length, neckline, pattern, etc.) but not fit. Estimate:
  probably ~60% of the 333k-anns corpus won't be useful for fit
  training.
- **Decision:** **Drop them from the training set** (don't default to
  `regular` — that would poison the class distribution). Document the
  resulting training-set size in `manifest.csv` and
  `ATTRIBUTE_TRAINING_PLAN.md`. Expected final size: ~55k crops.

### P2-5 — BBox edge cases

- **Source of bug:** COCO-format bboxes occasionally have out-of-bounds
  coordinates, near-zero areas, or extreme aspect ratios. Pushing these
  through a 224×224 resize produces garbage training signal.
- **Enforcement (preparer):**
  1. Clamp bbox to image bounds.
  2. Filter: drop if `bbox_area / image_area < 0.02` (tiny
     annotations — usually mis-labeled).
  3. Filter: drop if `aspect_ratio > 4.0` (extreme — usually long
     dresses or boots; squashing to 224×224 destroys texture/fit
     signal).
  4. Pad to square before the 224 resize (preserve aspect, add neutral
     gray border).

### P2-6 — Fashionpedia category-name casing / punctuation

- **Source of bug:** Fashionpedia v2 emits class names like `"t-shirt,
  top, sweatshirt"` (comma-space) and `"shirt, blouse"` — hyphens,
  commas, whitespace. Our `ClothingCategory.fromFashionpediaClass` uses
  lowercased() + specific underscore-joined tokens like
  `"top_t-shirt_sweatshirt"`. The preparer must emit the same
  underscore-joined form so the gating in P2-1 works.
- **Enforcement:** Normalize in one place —
  `fashionpedia_attr_to_ios_enum.py` exposes
  `normalize_class_name(raw: str) -> str` which does the
  `,` → `_` + whitespace-collapse mapping. All downstream gating calls
  this first.

### P2-7 — Image paths must be portable (local smoke + pod run)

- **Source of bug:** Local smoke test runs from
  `/Users/tarkansurav/...`; pod run runs from `/workspace/...`. Hardcoded
  absolute paths in `manifest.csv` break cross-environment training.
- **Enforcement:** `manifest.csv` emits paths **relative to the dataset
  root directory**. Training script reads a `--dataset-root` argument
  and joins the relative paths at load time.

---

## 🟢 DEFERRED (v1.1 or later-phase)

### D-1 — RulesTable has ~15 texture-conditional clauses unreachable under Option C

- **File:** [WardrobeReDo/Services/AttributeRules/RulesTable.swift](../../../WardrobeReDo/Services/AttributeRules/RulesTable.swift)
- **Symptom:** Clauses like `(.outerwear, _, .wool?)` and
  `(.dress, _, .silk?)` exist but will never match under Option C
  because the classifier never returns texture.
- **Impact:** ~20 lines of dead pattern matches. Correct code that
  reactivates for free in v1.1. Harmless but worth a header comment.
- **Action:** Add a comment block at the top of `RulesTable.swift`
  explaining "texture-conditional clauses are dormant under Option C
  (see ATTRIBUTE_TAXONOMY.md § Section 0) — they re-activate in v1.1
  once texture classification lands". **Fold into the Option C commit**
  as a lightweight one-shot, even though it's 'deferred' for functional
  purposes.

### D-2 — Phase 3 `train_attributes.py` must be single-head

- **Plan deviation:** Original Phase 3 spec called for a multi-head
  MobileNetV3-Small (texture + fit). Option C drops the texture head.
- **Spec:** Single 5-class softmax head over
  `[oversized, relaxed, regular, slim, cropped]`. CE loss with
  class-balanced weights (see P2-3).
- **Target metric:** ≥75% top-1 on val (achievable given `regular`
  dominates; the interesting signal is fit F1 per class — especially
  oversized which will be the stretch class).
- **Where tracked:** Update `docs/plans/2026-04-19-auto-attribute-detection.md`
  Phase 3 section when we get there.

### D-3 — Phase 4 real-mlpackage decode must handle missing texture outputs — DONE

- **File:** [WardrobeReDo/Services/Extraction/AttributeClassifierService.swift](../../../WardrobeReDo/Services/Extraction/AttributeClassifierService.swift)
- **Resolved 2026-04-19** in Phase 4 D-3 work: shipped
  `decodeHandlesSingleHeadFitOnlyOutput` regression test in
  [WardrobeReDoTests/Services/AttributeClassifierServiceTests.swift](../../../WardrobeReDoTests/Services/AttributeClassifierServiceTests.swift)
  that feeds a `fit_probs`-only `MLFeatureProvider` to
  `AttributeClassifierService.decode(prediction:)` and asserts:
    - `prediction.fit` decodes normally (e.g. `.regular` at 0.85)
    - `prediction.texture == nil`
    - `prediction.textureConfidence == 0.0` (exact equality, not `< threshold`)
- **Latent bug surfaced + fixed during D-3 work:** the iOS `fitLabels`
  array previously held all 6 `FitAttribute` cases including
  `.structured`. The Phase 4 mlpackage emits a `(1, 5)` softmax (Option
  C trainable subset). `argmaxSoftmax`'s `n == labelCount` shape guard
  would have silently swallowed every fit prediction. Fix:
    - Shrunk `fitLabels` to the 5-class trainable subset
      `[.oversized, .relaxed, .regular, .slim, .cropped]`
    - Mirrors `fashionpedia_attr_to_ios_enum.TRAINABLE_FIT_LABELS`
      exactly
    - New drift-guard test `fitLabelsLockOptionCTrainableSubset`
      pins the subset and asserts the count is exactly one less than
      `FitAttribute.allCases.count` (so growing the enum trips the
      test, forcing an intentional decision about whether the new case
      is trainable today)
    - `AddItemView` picker still iterates `FitAttribute.allCases` so
      users can manually pick `.structured` — only the auto-prediction
      decode path is restricted

### D-4 — Fashionpedia license attribution

- **License:** Fashionpedia v2 is **CC BY 4.0**. Requires attribution.
- **What's missing:** No credits surface in the iOS app that mentions
  Fashionpedia or the RF-DETR-Seg training lineage.
- **Action:** Add an "Acknowledgements" section to the Settings →
  About screen citing Fashionpedia + COCO + RF-DETR. Low functional
  priority; capture as v1.1 polish or pre-App-Store-submission
  checklist.

### D-5 — `TextureType.fur` iOS enum case missing

- **Source:** Fashionpedia attr **289 fur** has 730 annotations — one of
  the few fabric-type attributes with decent coverage. But our
  `TextureType` enum has no `.fur` case, so even Option B (richer
  dataset) can't surface it without an enum extension.
- **Action:** If Option B is ever picked, add `.fur` to `TextureType`.
  Migration implication: SwiftData + Supabase enum drift — needs a
  v1.1 migration.

### D-6 — `FitAttribute.structured` has no Fashionpedia signal

- **Source:** The 6-case `FitAttribute` enum includes `structured`
  (tailored, held-shape items like blazers). Fashionpedia has no
  `structured` attribute — blazers are labeled on main-class only, not
  on fit.
- **Current state:** The Phase 3 fit head will train on 5 classes
  (oversized / relaxed / regular / slim / cropped). `structured` stays
  user-input.
- **Future fix:** Rules engine can imply `structured` deterministically
  for `ClothingSubcategory ∈ {blazer, suitJacket}` — Phase 5 follow-up.
  Not a blocker for Phase 2.

### D-7 — RulesTable default falls back to "all seasons" for unmatched subcategory+category combos

- **File:** [WardrobeReDo/Services/AttributeRules/RulesTable.swift:178-180](../../../WardrobeReDo/Services/AttributeRules/RulesTable.swift)
- **Observation:** The `default: return Set(Season.allCases)` at
  the bottom of `seasons(...)` catches unreachable cross-category
  combos (e.g. `(.shoe, .fedoraHat, _)`). Swift's exhaustiveness check
  can't collapse them because `ClothingSubcategory` is a free product
  with `ClothingCategory`. Non-empty invariant is preserved.
- **Risk:** If a future refactor moves a subcategory from one category
  to another without updating the rules, users would see "all seasons"
  instead of the expected set. The existing exhaustiveness tests in
  `AttributeRulesEngineTests` catch this, but **we should add a
  property test** that iterates every real (category, subcategory)
  pair from `ClothingSubcategory.category` and asserts the returned
  seasons set is category-specific (not the default).
- **Action:** Add `AttributeRulesEngineTests.realPairingsNeverFallBackToAllSeasons`
  as part of Phase 5 polish. Not a v1 blocker.

### D-8 — Phase 9 dogfood must include an Option-C-aware correction analysis — DONE

- **Context:** Phase 9's 50-photo dogfood report was originally planned
  to measure texture pre-fill accuracy. Under Option C there's nothing
  to measure for texture. But the correction log will show users
  *manually* filling texture 100% of the time — which is the baseline
  v1.1 planning data.
- **Resolved 2026-04-19** — template shipped at
  [DOGFOOD_RESULTS.md](DOGFOOD_RESULTS.md). Includes:
    - Per-field acceptance summary with `texture` row marked `n/a (Option C)`
      and a forward-pointer to the manual-fill distribution table
    - "Texture manual-fill distribution" table covering all 15 `TextureType`
      cases + a "left blank" row — pulls from `wardrobe_items.texture`
      (NOT `detected_attributes`, since the AI never predicts texture in v1)
    - D-8-flagged note explaining the v1.1 prioritization use: top-5
      textures by manual-fill count are the v1.1 training scope
- All TBD cells fill in once the pod-side mlpackage lands and the
  50-photo dogfood is run.

---

## Cross-reference

| Blocker | Tracks to | Phase |
| ------- | --------- | ----- |
| I-1, I-2, I-3 | Option C sign-off commit | 1 (now) |
| P2-1 through P2-7 | `prepare_attribute_dataset.py` | 2 |
| D-1 | Option C sign-off commit (comment header) | 1 (now) |
| D-2 | `train_attributes.py` single-head | 3 |
| D-3 | `AttributeClassifierServiceTests` regression — DONE | 4 |
| D-4 | iOS About / Settings | 9 (pre-submit) |
| D-5 | `TextureType` enum expansion | v1.1 |
| D-6 | Rules engine follow-up | 5 (polish) |
| D-7 | Rules engine property test | 5 (polish) |
| D-8 | Dogfood report template — DONE | 9 |

## Next action

Fix I-1, I-2, I-3, and D-1 in this commit. Then start Phase 2 preparer
with P2-1 through P2-7 encoded as explicit script behavior.
