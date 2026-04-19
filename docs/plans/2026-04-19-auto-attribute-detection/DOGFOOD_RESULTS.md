# Phase 9 — Dogfood Results

> **Template (uncompleted).** Fill in once the trained
> `AttributeClassifier.mlpackage` is bundled and a 50-photo dogfood pass
> is run. Owner: pod operator who shipped the model. Reviewer: Tarkan.
>
> **Why this template exists:** Phase 9 needs a turnkey, machine-pasteable
> doc so the dogfooder isn't building the report skeleton at the same
> time as judging the model. The structure here is fixed; only the values
> are TBD.

---

## Run metadata

| Field | Value |
| ----- | ----- |
| Date run | YYYY-MM-DD |
| Operator | name |
| Build | `git rev-parse --short HEAD` |
| `AttributeClassifier.mlpackage` source | path or `attr_best.pth` checkpoint hash |
| `FeatureFlags.isAttributeDetectionEnabled` | `true` (set in Developer Menu before run) |
| Multi-garment flag | `true` |
| Device / sim | e.g. iPhone 17 Pro sim, iOS 17.4 |
| Photo set | brief description of the 50-photo composition |

---

## Photo composition (target 50)

Distribute photos across the matrix below. **No photo serves two cells**
— if a photo could land in two, pick the dominant case. The point is to
exercise category × subcategory diversity, not to inflate sample count.

| Bucket | Target count | Notes |
| ------ | -----------: | ----- |
| Tops — flat lay, plain background | 8 | shirt / tee / sweater mix |
| Tops — me-wearing, mirror selfie | 6 | exposes fit-prediction realism |
| Bottoms — flat lay | 6 | jeans / pants / shorts / skirt |
| Bottoms — me-wearing | 4 | |
| Dresses + jumpsuits | 4 | one-piece formality stress test |
| Outerwear | 6 | jackets, coats, blazers |
| Shoes — pair, side-on | 6 | sneaker / boot / heel / sandal mix |
| Accessories | 4 | bag / belt / hat — exercises rules engine fallback |
| Multi-garment outfit shots | 6 | full-body 2–3 garment compositions; tests proposal pipeline |
| **Total** | **50** | |

---

## Per-field acceptance summary

Fill from the `detected_attributes` JSONB column after the run. The
provenance values come from
[AddItemViewModel.computeAttributeProvenance](../../../WardrobeReDo/ViewModels/AddItemViewModel.swift)
which writes one of `"ai"`, `"user"`, or `"user_changed_from_ai"` per
field.

**Acceptance rate** = `count("ai") / (count("ai") + count("user_changed_from_ai"))`
restricted to predictions that actually pre-filled (i.e. confidence
≥ 0.80). User-from-blank (`"user"` with no AI snapshot) is **excluded**
because the model declined to predict — measuring the threshold's recall
at a different gate.

| Field | Pre-filled (n) | Accepted (kept "ai") | Changed (`user_changed_from_ai`) | Acceptance % | Phase 9 target |
| ----- | -------------: | -------------------: | -------------------------------: | -----------: | -------------- |
| category | TBD | TBD | TBD | TBD | ≥ 90 % |
| subcategory | TBD | TBD | TBD | TBD | ≥ 80 % |
| fit | TBD | TBD | TBD | TBD | ≥ 65 % |
| texture | n/a (Option C) | n/a | n/a | n/a | (deferred to v1.1; see D-8 table) |
| seasons | TBD | TBD | TBD | TBD | ≥ 75 % |
| occasions | TBD | TBD | TBD | TBD | ≥ 75 % |

**Pass / fail:** Phase 9 ships only if every cell ≥ target. If any
cell is below target, run the rule-table iteration (Phase 9 item 2)
or the optional retrain (Phase 9 item 3) before flipping the flag.

---

## Calibration sanity (≥0.80 threshold)

The Phase 3 `eval_attributes.py` calibration plot promised
`high_conf.realized_acc ≥ 0.90` at threshold 0.80 — the basis for
`AttributePrefill.minConfidence`. Dogfood validates that promise on
**real wardrobe photos** (Fashionpedia val ≠ user wardrobe).

Pull these from `summary.json` (training-time eval) AND from the
dogfood saves (`detected_attributes` rows with confidence ≥ 0.80, which
the iOS service logs to `os.log` under category `AttributeClassifier`):

| Source | Predictions ≥ 0.80 conf | Realized accuracy |
| ------ | ----------------------: | ----------------: |
| Phase 3 val set | TBD | TBD (target ≥ 0.90) |
| Dogfood (50 photos) | TBD | TBD (target ≥ 0.85; the gap reflects domain shift) |

If dogfood realized-accuracy < 0.85 at the 0.80 threshold, the
threshold should rise (e.g. 0.85) BEFORE the v1 ship — pre-filling
wrong values is worse than not pre-filling at all (user has to
notice + revert vs starting blank).

---

## Per-class fit precision (D-2 scope)

| Class | n predicted | Precision | Recall | F1 | Phase 9 target |
| ----- | ----------: | --------: | -----: | -: | -------------- |
| oversized | TBD | TBD | TBD | TBD | F1 ≥ 0.30 (rare class — stretch) |
| relaxed | TBD | TBD | TBD | TBD | F1 ≥ 0.45 |
| regular | TBD | TBD | TBD | TBD | F1 ≥ 0.70 (majority) |
| slim | TBD | TBD | TBD | TBD | F1 ≥ 0.50 |
| cropped | TBD | TBD | TBD | TBD | F1 ≥ 0.45 |

If `oversized` recall is near zero, that's OK for v1 — the
class-balanced sampler (P2 weights, `WeightedRandomSampler`) gave it
the floor it could realistically hit. Document it; don't retrain.

---

## D-8 — Texture manual-fill distribution (Option C v1.1 planning)

Texture is dormant in v1 (Fashionpedia v2 carries no main-fabric
attributes). Every user-saved item will have `detected_attributes
.texture == "user"` (no AI snapshot ever existed). The **distribution
of those manual texture picks** is the data v1.1 needs to scope the
DeepFashion / Wear-Theory texture training (Option B path).

Pull from `wardrobe_items.texture` for the 50 dogfood items:

| TextureType | Count | % of saves |
| ----------- | ----: | ---------: |
| cotton | TBD | TBD |
| silk | TBD | TBD |
| denim | TBD | TBD |
| leather | TBD | TBD |
| suede | TBD | TBD |
| wool | TBD | TBD |
| linen | TBD | TBD |
| knit | TBD | TBD |
| synthetic | TBD | TBD |
| velvet | TBD | TBD |
| satin | TBD | TBD |
| chiffon | TBD | TBD |
| tweed | TBD | TBD |
| corduroy | TBD | TBD |
| nylon | TBD | TBD |
| (left blank) | TBD | TBD |

**Use this for v1.1 prioritization:** the top-5 textures by count are
the ones a v1.1 texture model must nail. Anything in the long tail
(<2 %) is a rounding error.

---

## Rule-table iteration log

For each `(category, subcategory, texture)` triple where the user
changed the predicted seasons or occasions, log it here. After the
run, group by triple and update
[RULES_TABLE.md](RULES_TABLE.md) where correction rate ≥ 30 %.

| triple | predicted seasons / occasions | user-corrected to | n | action |
| ------ | ----------------------------- | ----------------- | -: | ------ |
| TBD | TBD | TBD | TBD | TBD |

---

## Crash + perf gate

| Metric | Baseline (multi-garment ON, attr OFF) | Dogfood (both ON) | Target |
| ------ | ------------------------------------: | ----------------: | ------ |
| Crash-free session rate | TBD % | TBD % | unchanged |
| Cold-start latency | TBD ms | TBD ms | < +200 ms |
| `predict(crop:)` p50 | n/a | TBD ms | < 80 ms |
| `predict(crop:)` p95 | n/a | TBD ms | < 200 ms |

`predict(crop:)` numbers come from `os.log` in
`AttributeClassifierService` — filter by category
`AttributeClassifier`.

---

## Decision

Date: YYYY-MM-DD

- [ ] All per-field acceptance ≥ target → **flag flip** OK to merge.
- [ ] Calibration realized-accuracy ≥ 0.85 → threshold stays 0.80.
- [ ] No crash regression → ship.
- [ ] Rule-table corrections logged + applied where ≥ 30 % rate.
- [ ] D-8 texture distribution captured → v1.1 backlog updated.

If any box unchecked, document the remediation and re-run.

---

## Appendix — re-run command

```bash
# 1. Fresh sim install with both flags ON
xcodebuild -scheme WardrobeReDo -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  clean build

# 2. Open Developer Menu → toggle isAttributeDetectionEnabled ON
#    (multi-garment flag should already be ON post-previous-release)

# 3. Capture the 50 photos following the composition table above.

# 4. Pull the provenance data from Supabase
psql $DB_URL -c "
  SELECT id, name, category, texture, fit, detected_attributes
  FROM wardrobe_items
  WHERE created_at >= 'YYYY-MM-DD'
  ORDER BY created_at;
" > dogfood_raw.csv

# 5. Tally with notebooks/dogfood/tally.py (TBD — quick aggregator
#    to fill the tables above from dogfood_raw.csv).
```
