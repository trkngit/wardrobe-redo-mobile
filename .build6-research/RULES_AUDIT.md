# Build 6 — Styling-rules audit

**Date:** 2026-05-11
**Auditor:** Claude (Sonnet 4.5)
**Scope:** 7-dimension outfit scorer, 50-archetype + 200-rule seed data, ENGINE.md provenance claims.

This document captures the audit that motivated Phase 5 (rules
integrity fixes) and the honesty corrections in ENGINE.md (Phase 7).
It is intentionally direct — these are the engine's actual
strengths and weaknesses as of build 5, not marketing copy.

## Summary

| Axis | Grade | Notes |
|---|---|---|
| Provenance | **2/10** | Zero citations to stylists, books, or published methodology. The "rooted in professional fashion theory" framing in ENGINE.md is aspirational. |
| Seed data quality | **5/10** | 50 archetypes + 200 rules are internally consistent but loosely bounded; "Capsule Essentials" archetype is contradicted by its own proportion constraints. |
| Implementation fidelity | **5/10** | The math runs as documented for the dimensions it covers; missing or partial implementations on three scorers. |
| Completeness | **4/10** | Three scorers had documented behavior they didn't deliver. Phase 5 closes those gaps. |
| Tuning transparency | **2/10** | Hand-tuned thresholds with no controlled-experiment basis. No statement about how the numbers were chosen. |
| Learning loop | **1/10** | No personalization. `wearCount` is never updated when an outfit is marked as worn. |

## What works

- **Color harmony** scores by family count, value spread, saturation coherence, and harmony classification. The math reads sensibly and the 0–1 range maps to recognizable styling outcomes.
- **Proportion balance** correctly handles the dress short-circuit and pin-points the worst pair (oversized × oversized).
- **Occasion context** correctly enforces season/occasion intersection and respects archetype-level boost/penalty conditions.

## What doesn't

### 1. VersatilityScorer — incomplete

Docstring (build 5):
> "Scores outfit versatility: item frequency penalty, novel combination bonus, least-worn item bonus."

**The novel combination bonus was never implemented.** The code at
`VersatilityScorer.swift` measured frequency (`wearCount`) and
recency (`recentOutfitItemIds`) but had no concept of "novel
pairing" — pairs of items the user hadn't worn together recently.

**`wearCount` was never incremented.** ENGINE.md §11 referenced an
`outfits.worn_flag` but no Repository call ever bumped
`wardrobe_items.wear_count` when the user marked an outfit as
worn, so the frequency math drifted from reality over time.

**Build 6 fix (Phase 5.1):** novelty bonus implemented as the
share of candidate-outfit item-pairs not seen in the user's last
30 saved outfits. `ScoringContext.recentOutfitItemPairs` provides
the history; the scorer emits a `coverage = 0` when no history
is available so fresh users aren't penalized. The `wearCount`
RPC + tap-handler are deferred — they require Supabase migration
work and a `OutfitViewModel` hook that wasn't critical for the
primary integrity fix.

### 2. FormalityCoherenceScorer — 75% of declared inputs missing

ENGINE.md (build 5):
> "Color brightness, texture smoothness, pattern, and structure move together."

The code at `FormalityCoherenceScorer.effectiveFormality(for:)`
implemented exactly **one** of those four inputs (texture
smoothness). A matte black formal dress and a sequined party
dress scored identically on the formality axis.

**Build 6 fix (Phase 5.2):** `effectiveFormality(for:)` now
returns `(value, coverage)` and combines four components:
- texture smoothness (weight 0.50, existing)
- color brightness via mean lightness (weight 0.20)
- pattern proxy via dominant-color count ≥ 3 (weight 0.15)
- structure derived from fit attribute (weight 0.15)

Per-item coverage flows up to the dimension's overall coverage,
so an outfit of well-tagged items scores with higher confidence
than one assembled from minimal-data items.

### 3. OutfitFormulaScorer — hand-rolled with uncited heuristics

ENGINE.md (build 5):
> "Hero-piece method, 2-of-3 color match, third-piece rule."

The hero-piece method has no published reference in fashion
literature — it's stylist common parlance. The 2-of-3 color
match is folk styling, not the visual-area 60-30-10 rule from
interior design (which the implementation *also* doesn't do —
the code divides item count, not pixel coverage). The
third-piece rule is real (Tim Gunn) but the scorer didn't say so.

**Build 6 fix (Phase 5.3):** decomposed into four named
sub-functions with provenance citations in the class docstring:
- Slot satisfaction — structural; no external source.
- Hero piece — Allison Bornstein, "3-Word Method."
- Color-family match — folk styling, NOT visual-area 60-30-10.
- Third-piece rule — Tim Gunn.

The math is unchanged; the reasoning text and code comments now
read honestly so future maintainers know which knobs are
research-backed and which are guesses.

## What we deferred

### 60-30-10 visual-area implementation

The audit flagged that ColorHarmonyScorer divides `dominant_colors`
percentages by `itemCount` instead of pixel coverage. A black
t-shirt + white pants scores 50/50 by the current logic but
reads 60/40 (or 70/30, depending on silhouette) visually.

Fixing this requires:
- Per-item silhouette area extraction (already approximated by the
  mask bounding box).
- A weighted aggregation across the outfit by silhouette area.
- A Supabase migration to persist the area metric.

This is a 2–3 day rebuild on its own. Deferred to a future build;
documented in ENGINE.md as an approximation.

## Take-aways for future builds

1. **Cite or honestly call out hand-rolling.** ENGINE.md's "rooted
   in professional fashion theory" was aspirational; the build 6
   ENGINE.md update softens this to "inspired by common styling
   guidance" with named citations where they exist.
2. **Don't ship documented features as dead code.** The
   `VersatilityScorer` novelty bonus sat in the docstring for the
   entire build-5 lifetime. Either implement it or remove it from
   the docs.
3. **Coverage > fallback magic numbers.** Phase 3's coverage
   field replaces opaque `0.5` fallbacks with explicit "we don't
   have data for this axis" — the engine no longer pretends to
   know things it doesn't.
4. **User control over strictness matters.** Phase 6's vibe slider
   addresses a category of feedback the engine couldn't satisfy
   before: "I want my outfits to be more / less adventurous
   without changing what I own."
