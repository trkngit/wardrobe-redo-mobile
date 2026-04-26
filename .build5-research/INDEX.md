# Build-5 Research Workspace — INDEX

> Generated 2026-04-26 from build-4 dogfood + 9 parallel research agents + Supabase production audit. **Read this file first** before reading individual research files.

## Quick links

- **Final canonical plan:** `/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/docs/plans/build-5-capture-display-rework.md`
- **Source screenshots:** `/Users/tarkansurav/Downloads/After build 4/IMG_2512..2521.PNG`
- **Original plan file (handoff):** `/Users/tarkansurav/.claude/plans/read-docs-session-handoff-brief-md-for-t-velvet-flamingo.md`

## File map

### `screenshots-analysis/`
- `findings.md` (36 lines) — Per-screenshot bug catalog. Read first to understand what the user is seeing.

### `supabase/`
- `production-state.md` (98 lines) — Direct DB query results from the build-4 multi-pick batch. Confirms which fields are populated, which are null, and the masked-image upload paths.

### `agents/` — Code exploration findings
- `A-color-extraction.md` (68 lines) — k-means RGB pipeline, why 5 nearly-identical shades + skin-tone leak.
- `B-multigarment-subcategory-texture.md` (113 lines) — Pipeline trace for bugs A-G (sneakers→boots, sunglasses→hat, etc).
- `C-display-masking-match-outfit.md` (100 lines) — **CRITICAL:** `MaskProposal.maskedImage` is a rect crop, not a real cutout.
- `D-save-path-supabase.md` (75 lines) — Upload flow trace + worn-outfit feasibility.
- `E-match-outfit-dedup.md` (62 lines) — Match tab + Outfit cards have the same source-photo-backdrop bug as the wardrobe grid had pre-PR-#20.

### `web-research/` — External research
- `F-color-extraction-soa.md` (664 lines) — CIELAB, CIEDE2000, cluster merging, perceptual color science.
- `G-ios-isolation-best-practices.md` (825 lines) — iOS Vision framework, RFDETR-Seg masks, white-card composition. **Includes code-ready Swift snippets.**
- `H-wardrobe-ux-competitive.md` (843 lines) — Whering / Acloset / Cladwell / Indyx / etc. UX patterns. **Top recommendation:** Whering's mass-tagging.
- `I-form-overwhelm-ml-ux.md` (505 lines) — Progressive disclosure, ML-confidence display, Hick's law application.
- `J-rfdetr-fashionpedia-classes.md` (383 lines) — **CRITICAL:** Authoritative class list. Model emits `shirt_blouse`, `top_t-shirt_sweatshirt`, `bag_wallet` (UNDERSCORES); has NO `sneaker`/`jeans` classes at all.
- `K-design-critique-redesign.md` (452 lines) — Senior designer's opinionated redesign. **Includes UX patterns + SwiftUI primitives + priority ranking.**

### `drafts/`
- `build-5-plan-draft.md` (320 lines) — Earlier draft (superseded by canonical plan).

## Top-level findings (TL;DR)

### Capture-pipeline bugs (BLOCKERS)
1. **Multi-pick "masked image" is a rect crop, not a real cutout** — root cause of every "source photo backdrop" complaint. RFDETR-Seg DOES produce per-instance masks; we never composite them. Fix: `MultiGarmentProposalService.compositeMaskedItem()` using the existing `raw.mask`.
2. **Subcategory rescue logic broken for accessories** — when model emits `glasses` or `belt`, the `predictedSubcategory` gets set to something accessory-class, the first branch in `applyPrefill` accepts it without consulting the rescue. Need to invert order for accessories.
3. **Model emits class names with underscores** — Agent J's discovery. Cases like `"sunglasses"`, `"trousers"`, `"jeans"`, `"cap"`, `"gown"`, `"bag"`, `"wallet"` in our switch are dead code. Real classes: `glasses` (not `sunglasses`), `top_t-shirt_sweatshirt`, `shirt_blouse`, `bag_wallet`.
4. **No sneaker / jeans classes in Fashionpedia** — Fashionpedia uses `shoe` and `pants` as categories; sneaker/boot/jeans are ATTRIBUTES (model has no head for them in our 33-class subset). Cannot fix via mapping; needs secondary classifier or improved defaults.
5. **Texture rules don't fire for multi-pick** — flag/path issue in `applyPrefill`.
6. **Color extraction picks shadow as dominant** — k-means in RGB on 50×50 downsampled image with 128-alpha-threshold. Shadow regions dominate; soft-edge mask leaks skin tones.

### Display-layer bugs (HIGH)
7. **Match tab + Outfit cards bypass `displayPath`** — only `MatchingViewModel.swift:173`, `OutfitViewModel.swift:350,359` need fixes (3 lines).
8. **Wardrobe card layout** — `scaledToFill` + min height + dark gray bg → items look stretched + edge-clipped + inconsistent vs industry (white bg + scaledToFit + padding).

### UX (HIGH but harder)
9. **6 sequential forms = 35 decisions × 6 items = 210 decisions per multi-pick.** Per Agent K: replace with a Confidence-Triaged Review Wall — single screen, low-conf items auto-expanded, high-conf collapsed.
10. **Color UI surfaces engineering data** (5 swatches, percentages) — replace with single editorial color name (e.g., "Indigo") + optional "+2 accents".
11. **No "Worn Outfits" entity** — source photo is currently per-item denormalization. Promote to first-class entity with sub-tab in Wardrobe.

## Context-resilience pattern (for future projects)

If a session runs out of context, the next session can resume from `INDEX.md`. Each research file is self-contained — read in any order.

**Pattern:**
1. Create `.build5-research/` (or similar) at project root
2. `INDEX.md` always at the top — explains what's where
3. `agents/` — code exploration outputs (one file per agent)
4. `web-research/` — external research (one file per topic)
5. `screenshots-analysis/` — user-supplied artifacts catalog
6. `supabase/` (or DB) — production-data inspection results
7. `drafts/` — work-in-progress plan revisions
8. **Final plan lives in `docs/plans/<name>.md`** — version-controlled with code

This keeps context-loss from being catastrophic. Anyone (human or LLM) opens `INDEX.md` and resumes.
