# K — Build 5 Design Critique & Redesign Recommendations

**Reviewer:** Senior product designer
**Source material:** Dogfood screenshots IMG_2512–2521 (TestFlight build 4), live source files in `WardrobeReDo/Views/`
**Stance:** Opinionated. The current UX is failing the user in ways the user has correctly diagnosed and in several ways they have not. This document tells the team what to ship in Build 5, not what to consider.

---

## TL;DR — One paragraph

Build 4 is a bag of *technically correct* affordances that ignore how humans actually use a wardrobe app. The multi-pick form makes the user pay tuition six times for a single mirror selfie — six categories, six subcategories, six 12-chip texture grids, six color-percentage panels — when the real job is "log the clothes." The wardrobe grid is visually inconsistent because two different upload paths produce two different image kinds. Color extraction surfaces engineering ground-truth (5 swatches, percentages) when the user wants editorial truth ("this is a dark blue jean"). And there is no concept of a *worn outfit*, even though the user is literally taking outfit-of-the-day mirror selfies as the entry point. Build 5 should: (1) collapse the 6× form into a one-screen review wall with low-confidence triage, (2) standardize the grid with white card backgrounds and aspect-fit cutouts, (3) replace 5 swatches with one editorial color, (4) introduce a first-class "Worn Outfits" timeline that owns the source photo, and (5) hide every advanced field behind progressive disclosure so the default save flow is **two taps**.

---

## 1. Critique — Beyond the user's stated list

The user identified six concrete problems. Here are six more they did not mention but that I would flag as P0/P1 if I were the design lead.

### 1.1 The form is performing engineering, not product
**Pattern violated:** *Smart defaults + recognition over recall* (Nielsen heuristic #6).

The Build-4 form treats every ML attribute as something the user must *read, evaluate, and confirm*. Twelve texture chips, six fit chips, four season chips, six occasion chips, five color swatches, two pickers — that is **35 distinct decision points per item × 6 items = 210 decisions for one mirror selfie.** No human will do that. The user has correctly stopped trying. Every wrong prediction this user accepted (sneakers→Boots, sunglasses→Hat) is the system's fault for *asking the question in the first place* when the answer was already wrong with high confidence. The form's job is not "let the user fill in everything"; it is "let the user fix the things the model got wrong, fast."

### 1.2 Confidence numbers are noise, not signal
The grid card shows "Shoes 92% / Shoes 91%" — both wrong (one's a duplicate). Numeric confidence percentages give the user a false sense of precision and zero actionable information. 92% feels right; 60% feels suspicious. But IMG_2516 has high-confidence "Hat" labels on sunglasses *and* a belt. Confidence is calibrated to the model's loss function, not to the user's accuracy needs. Showing it numerically (a) anchors the user on the wrong thing, (b) makes them less likely to correct obvious errors because "the AI seems sure," and (c) leaks model internals into the UX. Ship a binary: confident → silent commit; not confident → ask.

### 1.3 The grid header makes 1-item sessions awkward
The capture-session grouping (PR #20) is good for batches but makes solitary captures look orphaned. A single-item session renders as a header (44×44 thumbnail + "1 item · 2h ago") above a *one-card grid that's only half the row width*, which produces a visually unbalanced row with the right column empty. The grouping logic already fuses *consecutive* singles into a shared grid (`groupedSessions.singles`), but the moment a session has 1 item between two multi-item batches, it gets an over-engineered header for nothing.

### 1.4 The Match tab and Outfit cards leak the source-photo backdrop
The user noted this for the wardrobe grid. It also affects the Match tab piece selector (top of IMG_2521) and outfit cards (bottom). Three views render the same kind of image with three different fallbacks, because PR #20 only fixed `WardrobeGridView`/`ItemCardView`. The *display* of an item should not be three different surfaces independently choosing what to render — there should be one `ItemThumbnailView` component used everywhere, with the `maskedImagePath ?? thumbnailPath` rule baked in once. This is a design-system smell that became a visible bug.

### 1.5 The form is shaped like the database, not like a human
Look at the Edit/Add form's section order: Category → Subcategory → Texture → Fit → Seasons → Occasions. That's the column order in `wardrobe_items`. A human's mental model when looking at jeans is: "What is it (jeans) → What's it like (dark blue, denim) → When do I wear it (casual, all year)." The form should be three groups: **Identity** (category/subcategory) — **Look** (color/texture/fit) — **Use** (seasons/occasions). And only the first group should be visible by default; the rest should be progressive disclosure under a single "Add details" expander.

### 1.6 The "0%" color cluster and skin-tone leakage are a trust collapse
IMG_2516 shows a color palette where one swatch reads "0%" — that's a UI-layer logic bug, but the user reads it as "this app is broken." Then sunglasses extract the user's *facial skin tone* into the palette. These are not edge-case oversights; they are the moment a user decides not to recommend the app. Ship a minimum-percentage filter (drop anything <3%) and a skin-tone exclusion in color extraction (CIELAB-based skin-cluster suppression — hue 20–50, saturation < 0.4, lightness 0.5–0.85). Both are <50 lines of Swift.

### 1.7 Category chips + Subcategory dropdown is two affordances doing one job
The form has segmented Category chips (`Tops/Bottoms/Outerwear/Shoes/Accessories/Dresses`) followed by a Subcategory `Picker(.menu)`. This is a hierarchical taxonomy displayed as two flat affordances. It works, but it makes the user pay attention twice. A single search-driven combobox ("Type or pick: jeans, joggers, tee…") with a recents row would let the user type "jeans" and be done. The category gets inferred from the subcategory, not the other way around. Apple's Mail-folder picker, Notion's database property picker, Linear's labels — all use this pattern.

### 1.8 No "fix the prediction in place" affordance on the grid
When the multi-pick grid shows "Shoes 92%" on a clear close-up of laces (which is a *duplicate* of an earlier card), the user has to: deselect → save the rest → realize on the wardrobe grid → tap into the item → tap Edit → fix subcategory → save. That's 5 taps to fix one wrong prediction. The grid card itself should let the user long-press → "Change category" inline. The model can be wrong; the UX should not punish the user for the model's mistake.

### 1.9 The "Skip this item" toolbar button is hidden in plain sight
The progress bar says "Item 3 of 6" — but the way to stop reviewing item 3 is a small text button in the navigation bar's top-right. Users don't read navigation toolbars; they look in the form. The skip affordance should be a tertiary button next to the primary "Save to Wardrobe" CTA, labeled clearly: "Skip this one — won't be added."

### 1.10 The detail view's bbox overlay is sophisticated and wrong-headed
Migration 00013 added a dim-everything-but-bbox overlay so the detail view can show "this is the part of the photo that is *this item*" (PR #21). It's a beautiful piece of code (`aspectFitRect`, `BoundingBoxHoleShape`, eo-fill — chef's kiss). But the user's actual mental model is "I want to see the cutout, and separately I want to see the original photo I was wearing." The bbox-on-source-photo is solving the problem the wrong way: it's optimized for engineers proving the segmentation worked, not for users browsing their wardrobe. The detail view should lead with the **clean cutout** on white, with a secondary affordance ("View in original photo") that opens a sheet to the `WornOutfit` (see §4 below).

---

## 2. Multi-pick flow — Redesigned

### Goal
Reduce the per-item form burden from 35 decisions to **0 decisions for items the model is sure about, and at most 2 decisions for items it's not.**

### Architecture: One Review Wall, Not Six Forms

Replace the current "Multi-pick grid → loop 6× through ItemFormView" flow with:

```
Mirror selfie
  → MultiGarmentGridView   (unchanged — pick which garments to keep)
  → ReviewWallView         (NEW — single screen, all 6 items, only low-conf items expanded)
  → Wardrobe (saved)
```

### Pattern: **Confidence-Triaged Review Wall**

**Design pattern name:** Smart defaults + selective review (Apple Photos "Review Suggestions" pattern; Google Photos "Best of August" categorization).
**Industry citation:** Apple Photos' face-recognition review screen — it surfaces only the faces it can't auto-confirm, lets you bulk-merge similar suggestions, and never asks you to confirm the obvious ones.

**What the user sees:**
- A vertical scrolling list of 6 cards, one per detected garment.
- **High-confidence items render collapsed** with: cutout thumbnail (left, 64×64), category + subcategory ("Shoes · Sneakers"), and a single editorial color chip. No form. No texture chips. No season chips.
- **Low-confidence items render auto-expanded** with: cutout (top, 200pt), 2-tap fix row ("Sneakers ✓ · Boots · Loafers · …" — the top 3 model alternatives plus a "More" expander), and a single "Looks right" tertiary button to dismiss the warning.
- Sticky footer: "Save 6 items" primary button, "Review skipped (1)" secondary.

**SwiftUI primitives:**
- `LazyVStack` of `ReviewItemRow` — each row is a `DisclosureGroup` whose `isExpanded` state defaults to `!proposal.isHighConfidence`.
- Inline category fix uses a horizontal `ScrollView(.horizontal)` with chip-style `Button`s for top-3 alternatives.
- Sticky footer: `.safeAreaInset(edge: .bottom)`.

**The math the user pays:**
- 6 high-confidence items: **0 decisions, 1 tap to save.**
- 6 items, 2 low-confidence: **2 decisions (one tap per fix), 1 tap to save = 3 taps total.**
- Worst case (all 6 wrong, current Build 4 reality): 6 inline fixes + 1 save = 7 taps. *Still 30× better than 35 chips × 6 items.*

### Pattern: **Progressive Disclosure for Advanced Fields**

**Design pattern name:** Progressive disclosure (Tognazzini's First Principles of Interaction Design).
**Industry citation:** iOS Settings — "General" shows 8 things; tap one to drill into 30 more. Notion's `+ Add property` — properties are hidden until you ask.

Texture, fit, seasons, and occasions **never appear on the review wall.** They are not part of the daily logging job. Logic:

- The model fills all four fields with its best guess on save.
- If the user *never* opens advanced details on an item, it stays as-saved. The style engine has enough signal to work.
- The item detail view has one row: "Add details" — taps into a `.sheet` with the existing `ItemFormView` body. Power users get the full form on demand.
- Onboarding teaches this once: "We've filled in the basics. You can fine-tune any item later."

**SwiftUI primitives:**
- `Section { Button("Add details", systemImage: "slider.horizontal.3") { showAdvanced = true } }` on `ItemDetailView`.
- `.sheet(isPresented: $showAdvanced) { ItemFormView(...) }` reusing the existing component as-is (no new code).

### Pattern: **Bulk-Confirm + Skip-Review-Later**

**Design pattern name:** Inbox triage (Gmail Priority Inbox; Linear Triage view).
**Industry citation:** Gmail's "Mark all as read" + Linear's `/triage` queue.

The footer of the review wall has three actions:

1. **`Save 6 items`** — primary. Saves everything, including auto-detected attributes.
2. **`Skip review · save anyway`** — tertiary text link. Same effect as Save, but visually marks the review as deferred (yellow dot on the wardrobe grid items for 24h, dismissible). Lets the user save *now* and review *later* over coffee.
3. **`Cancel`** — top-left toolbar. Throws away the entire batch.

There is **no "skip this item" within the wall.** If the model proposed it, the user is committing to save it. To remove an item, deselect it on the *previous* `MultiGarmentGridView` step. The wall is for review, not for selection — separating those two jobs is what makes the UX legible.

**SwiftUI primitives:**
- `safeAreaInset(edge: .bottom)` with `HStack` of `GoldButton` + `Button(.borderless)`.
- "Yellow dot" later-review indicator: a small overlay on `ItemCardView` driven by an `isReviewPending: Bool` flag persisted on the item, computed as `created_at > now - 24h && advanced_attrs_unset`.

### Pattern: **Skin-Tone-Aware, Median-Color Display**

**Design pattern name:** Editorial reduction.
**Industry citation:** Pinterest's "color story" extraction — collapses near-duplicates into a single representative; The/StudioCloset's Save-as-One-Color UX.

Replace the 5-swatch panel with **one big chip + an "Accent colors" expander**:

- **Hero swatch:** A 56×56 circle showing a single color computed as the *L* a* b* median* of the dominant cluster *after skin-tone suppression and lightness collapse.* Label below: "Indigo" (the named color family, capitalized).
- **Accent colors:** A small "+ 2 more" affordance. Tapping reveals up to 3 secondary colors in 24×24 chips. No percentages — they are decorative, not informational.

**Why median-color, not the model's top hex:**
- 5 shades of blue from one pair of jeans is the *same* perceptual color rendered under varied lighting. Users do not think "I have indigo, navy, dark slate, slate, and steel blue jeans." They think "I have dark blue jeans."
- Median in CIELAB collapses lighting variation while preserving the human-perceived color. This is the same trick used by Adobe Color and Behance.
- Skin-tone suppression: drop any cluster whose *L* a* b* falls in the human-skin gamut* (a* ∈ [10, 25], b* ∈ [10, 30], L ∈ [40, 85]) before computing the median.

**SwiftUI primitives:**
- New `EditorialColorView(color: ColorProfile, accents: [ColorProfile])` component. Replaces every site that uses `ColorSwatchView(showPercentage: true)`.
- The `+2 more` expander is a `Button` that swaps the trailing content from a count badge to a `HStack` of small circles via `withAnimation(.spring)`.

### Pattern: **Categorical Confidence (or Hidden)**

**Design pattern name:** Threshold-based binary states.
**Industry citation:** Photos.app face-recognition uses "Suggested" vs nothing — never a number.

Replace numeric confidence (`92%`) with one of three states:

| State | When | Visible UI |
|---|---|---|
| Confident | `score ≥ 0.85` AND not in known-mislabel set | **Nothing.** No badge, no number. |
| Uncertain | `0.6 ≤ score < 0.85` OR known-mislabel category (sunglasses → hat) | Small caption-size text under category: `Tap to confirm`. Tappable. |
| Unsure | `score < 0.6` | Card auto-expands on review wall with top-3 alternatives. Caption: `We weren't sure — pick one`. |

Numbers never appear in user-facing UI. Numbers go to the dev-menu MLDiagnosticsView for debugging.

---

## 3. Wardrobe Grid — Redesigned

### Goal
**One visual language across every place an item is rendered.** Square cutout, white background, consistent padding, no source-photo backdrops, ever.

### Pattern: **Uniform Aspect-Fit Card**

**Design pattern name:** Standardized object cards (Apple's "Looking up: A Photographic Object Manual").
**Industry citation:** SSENSE, Net-a-Porter, Mr Porter — every product card on the planet is an aspect-fit cutout on white. Wardrobe apps that get this right (Whering, Save Your Wardrobe, Acloset) all do the same.

**Card spec:**
- **Background:** Pure white (`#FFFFFF`) on light mode; `#1C1C1E` (system secondaryBackground) on dark mode. *Not* the current `Theme.Colors.surface` if that resolves to a tinted gray — bring it to true neutral so the cutout reads as object, not decoration.
- **Aspect ratio:** 1:1 square. Every card. No exceptions.
- **Image rendering:** `Image(uiImage: cutout).resizable().scaledToFit().padding(16)`. The 16pt padding is what makes a sunglasses item read at the same visual size as a t-shirt — both fill ~70% of the card edge.
- **Cutout source:** `maskedImagePath` only. If `maskedImagePath` is nil (legacy items), run a one-time backfill that re-extracts the cutout via the existing pipeline. *No fallback to the source photo.* Ever.
- **Foreground content:** Subcategory label (top-left, light material chip), single hero color dot (bottom-left, 12pt), wear count (bottom-right). Nothing else on the card itself.

**SwiftUI primitives:**
```swift
ZStack {
    Color.white  // or Color(uiColor: .secondarySystemBackground)
    Image(uiImage: cutout)
        .resizable()
        .scaledToFit()
        .padding(16)
}
.aspectRatio(1, contentMode: .fit)
.clipShape(RoundedRectangle(cornerRadius: 16))
.overlay(/* labels */)
```

### Pattern: **Single Component for Every Surface**

**Design pattern name:** Design-system tokenization (Material 3 component contract; Apple HIG component reuse).
**Industry citation:** Stripe's `Card` component — used in 23 places, defined once.

Create `ItemThumbnailView` and use it in:
- `WardrobeGridView` (currently `ItemCardView`)
- `MatchingView` piece selector
- `OutfitCardView` itemThumbnailStrip
- `ReviewWallView` rows
- `ItemDetailView` hero (above the source-photo affordance)

The component takes `(item: WardrobeItem, size: ThumbnailSize)` and *internally* resolves `maskedImagePath ?? backfillCutout`. Three sizes: `.small (44pt)`, `.medium (160pt)`, `.large (full-width)`. This kills the source-photo bug class permanently, because any new surface that wants to show an item *must* go through this view.

### Pattern: **Adaptive Session Grouping**

**Design pattern name:** Conditional UI weight (Material's "density" tokens).
**Industry citation:** Apple Photos' Year/Month/Day adaptive headers — a single-photo "day" doesn't get its own header section.

Current behavior is already 80% there (`groupedSessions.singles` fuses consecutive singletons). The remaining 20%:

- **`Singles` group:** Pure 2-column grid, no header. Already works.
- **`Session` group with N ≥ 2 items:** Header with 44pt source-photo thumbnail, "N items · 2h ago," and a chevron-right that opens the WornOutfit detail (see §4).
- **`Session` group with N = 1 item:** Demote to a single in the surrounding `Singles` group. Don't render a session header for one item — it adds 56pt of vertical noise for zero info gain.

**Implementation hint:** in `WardrobeViewModel.groupedSessions`, change `.session(s)` → `.singles([s.items[0]])` when `s.items.count == 1`. One line. Tests pin: a 1-item session inside a run of singles ends up in the same `.singles` group.

### Pattern: **Session Header → WornOutfit Affordance**

The session header thumbnail (currently a 44×44 source photo) should be a *navigation entry point* to the WornOutfit detail view, not just decoration. Tappable. Chevron-right at trailing edge. VoiceOver: "Capture session, 6 items, taken 2 hours ago, opens worn outfit."

---

## 4. "Worn Outfits" — New first-class entity

### IA decision: **Sub-tab of Wardrobe, not a top-level tab**

**Design pattern name:** Hierarchical IA (Apple HIG).
**Industry citation:** Apple Photos' Library/For You/Albums tabs — Albums is a sub-organization of the Library, not a peer.

Top-level tabs are scarce real estate (currently Wardrobe / Outfits / Match / Profile). Adding a fifth tab would fragment the user's mental model. Better: turn "Wardrobe" into a two-segment view.

**Wardrobe tab layout:**
```
[Items]  [Worn]   ← segmented control under nav title
```

- **Items segment:** today's `WardrobeGridView`, but with the redesigned grid (§3).
- **Worn segment:** chronological feed of `WornOutfit` records.

**Why not the Outfits tab?** Outfits tab is for *generated* (style-engine) suggestions. Worn outfits are *captured reality*. Putting them in the same tab muddles "what should I wear" with "what did I wear" — distinct jobs, distinct surfaces.

### Data model: `worn_outfits` table

A `WornOutfit` is created automatically every time a multi-pick batch saves ≥2 items, and manually via "Mark as worn outfit" on any single item or session.

```sql
create table worn_outfits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  source_photo_path text not null,        -- the mirror selfie
  source_photo_thumbnail_path text,
  worn_at timestamptz not null default now(),
  notes text,                             -- optional user note
  created_at timestamptz not null default now()
);

create table worn_outfit_items (
  worn_outfit_id uuid references worn_outfits(id) on delete cascade,
  wardrobe_item_id uuid references wardrobe_items(id) on delete cascade,
  primary key (worn_outfit_id, wardrobe_item_id)
);
```

Note: this is the *correct* place for the source-photo path. Today, `wardrobe_items.sourcePhotoPath` is doing the job because there was no entity for "the outfit I wore." Promoting it to its own table lets each item live as a clean cutout while the original full-body photo lives where it belongs — attached to a moment in time.

### View: `WornOutfitsTimelineView`

**Design pattern name:** Photo-feed timeline (Instagram, BeReal, Apple Photos' "For You" memories).
**Industry citation:** BeReal's daily card; Pinterest's saved-by-date board.

**Layout (top-to-bottom scroll):**
- Date headers (relative: "Yesterday," "3 days ago," "Last week," then `Mon, Apr 21`).
- Each `WornOutfit` card:
  - **Top:** full-width source photo, ~16:9 cropped, with `Color.black.opacity(0.2)` gradient overlay so labels read.
  - **Bottom strip:** horizontal scroll of item cutouts (using `ItemThumbnailView(.small)`), 56pt tall, 8pt padding.
  - **Tap target:** entire card → `WornOutfitDetailView`.
- Floating-action `+` button (`.safeAreaInset(edge: .bottom)`) → "Mark today's outfit" flow (camera → multi-pick → review wall, but the destination is a WornOutfit not just items).

**SwiftUI primitives:**
```swift
ScrollView {
    LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
        ForEach(groupedByDate) { dateGroup in
            Section {
                ForEach(dateGroup.outfits) { outfit in
                    WornOutfitCard(outfit: outfit)
                }
            } header: {
                DateHeader(date: dateGroup.date)
            }
        }
    }
}
```

### View: `WornOutfitDetailView`

- Hero: full source photo, tappable to zoom (system `.fullScreenCover` with pinch-to-zoom).
- Below: 2-column grid of item cutouts using `ItemThumbnailView(.medium)`.
- Each cutout is a `NavigationLink(value: item.id)` into the existing `ItemDetailView`.
- Toolbar: Edit notes, Delete worn outfit (does not delete items).

### Pattern: **Auto-create on multi-pick batch**

**Design pattern name:** Implicit creation with explicit control.
**Industry citation:** Apple Photos' auto-generated "Memories" — created without asking, dismissible, tunable.

When a multi-pick batch with ≥2 items saves successfully, automatically create a `WornOutfit` record linking those items + the source photo. Show a one-time toast on first creation: "We saved this as a worn outfit. View it in Wardrobe → Worn." Subsequent batches are silent.

For single items the user is logging from a worn-as-photo (mirror selfie of just shoes), expose a "Mark as worn" action in `ItemDetailView` toolbar — promotes the item's `sourcePhotoPath` (if any) into a 1-item `WornOutfit`. If no source photo exists, show "No worn-photo on file — take one?" → camera.

### Optional: Calendar view (V2, not Build 5)

After the timeline ships and we have data on engagement, V2 can add a `Calendar` segmented option that maps `WornOutfit`s to a month grid (Apple Health-style date dots). Not needed for Build 5 — the timeline is the right primary view, and calendars are a sparseness amplifier (most days will be empty in early use).

---

## 5. Texture / Fit — Chip group redesign

### Problem
12 texture options is too many. The user has to scan: cotton, silk, denim, leather, suede, wool, linen, knit, synthetic, velvet, satin, chiffon, tweed, corduroy, nylon. Half of these are formalwear textures the user (a casual male wearer based on the screenshots) will never select. The model rarely fills it correctly. So the chip grid is a graveyard.

### Pattern: **Smart-default + top-3 alternatives + "Other…"**

**Design pattern name:** ML-suggested choice with escape hatch.
**Industry citation:** Gmail Smart Reply (3 suggestions + Compose); Apple Mail "+ Suggested Recipients" with Show All.

**Default state (texture not yet user-edited):**
- Display the model's top guess as a single read-only chip with a small `pencil` icon: `Denim ✏️`. No grid visible.
- Tapping reveals top-3 alternative chips inline + an "Other…" chip.
- Tapping "Other…" opens a `.sheet` with the full 15-texture grid grouped by family:
  - **Casual:** cotton, denim, linen, knit, jersey
  - **Smart:** wool, tweed, corduroy
  - **Luxury:** silk, satin, velvet, chiffon, suede
  - **Technical:** synthetic, nylon

The grouping is meta-information that helps the user navigate, exactly like Apple's emoji picker categorizes 1800 emojis into 9 groups.

### Pattern: **Texture as Inferred-Default-Acceptable**

If the user *never* opens texture in advanced details, the saved value is the model's prediction. The wear-and-style engine treats it as soft signal. There is **no required field** for texture. Forcing the user to "pick one" yields garbage data — accepting "we don't know yet" yields no data, which is more honest.

**SwiftUI primitives:**
- `DisclosureGroup` for the inline expansion.
- `.sheet` for the "Other…" full picker.
- The full picker uses `LazyVGrid` with `Section` headers per family.

### Fit (6 options) — keep the current 6-chip horizontal row

Fit chips are fine as-is. 6 options, single-row, mutually exclusive — this is the textbook use case for a chip group. The only change: pre-select the model's prediction (currently nothing is pre-selected per IMG_2514, "Fit: nothing selected"), so the user's job becomes "change if wrong" not "fill in from scratch."

---

## 6. Color display — One color, not five

### Pattern: **One Hero Color + Optional Accents**

**Design pattern name:** Editorial reduction.
**Industry citation:** Adobe Color's "Extract from Image" → 5 raw colors, but every consumer surface (Pantone Studio, Coolors single-color view) shows ONE.

**Replace `ColorSwatchView(showPercentage: true)` with `EditorialColorView`:**

```
┌──────────────────────────┐
│   ●     Indigo           │  ← 56pt circle, color name in h3
│         Dark blue        │  ← family in caption
│   ＋ 2 more accents      │  ← tappable, expands to small chips
└──────────────────────────┘
```

**Behind the scenes:**
- Run color extraction as today (5 clusters in CIELAB).
- **Skin-tone suppression:** drop any cluster whose *Lab* falls in the skin gamut (see §1.6).
- **Lightness collapse:** for clusters whose *Lab* are within `ΔE76 ≤ 5.0` of each other, merge them weighted by cluster size. This kills the "5 shades of blue" problem at the source.
- **Hero selection:** the largest remaining cluster, by pixel count.
- **Accent selection:** up to 3 additional clusters, only if `ΔE76 ≥ 10` from the hero AND each ≥ 8% of pixels.
- **No hero, just 1 cluster, just hero:** all valid states. The view handles 1, 2, 3, or 4 cluster cases gracefully.

**The percentage label is gone, completely.** "26%, 23%, 22%" tells the user nothing they can act on. Color naming ("Indigo," "Charcoal," "Cream") tells them what to remember. Use `XKCDColorNamer` or a small CIELAB → English name table — a 100-line lookup is plenty.

**SwiftUI primitives:**
- `EditorialColorView` is a `VStack` with the hero `Circle` + `VStack(.leading)` for name/family, plus a trailing `Button("+\(accents.count) more")` that toggles a horizontal `HStack` of small chips.
- The accent chips are tap targets that show an HUD with the color hex on long-press (debug + design-curiosity affordance).

### Where the percentage data goes

Persisted in `wardrobe_items.dominant_colors` JSONB as today — the style engine still uses cluster percentages for color harmony scoring. The change is purely UX: percentages were always engineering data, never product data.

---

## 7. Confidence display — Hidden, with one trapdoor

### Pattern: **Silent-Confident, Tap-To-Confirm-Uncertain**

**Design pattern name:** Trust-by-default, prompt-by-exception.
**Industry citation:** iOS spell-check — autocorrects silently when confident, underlines when unsure, *never* shows a confidence number.

| Confidence band | Multi-pick grid card | Review wall row |
|---|---|---|
| `≥ 0.85` AND clean | No badge | Collapsed, no warning |
| `0.6–0.84` OR known-mislabel-category | No badge on grid card; review wall shows caption "Tap to confirm category" | Auto-expanded with top-3 alternatives |
| `< 0.6` | No badge on grid card | Auto-expanded; caption "Pick one — we weren't sure" |

The dev-only `MLDiagnosticsView` keeps the numeric values for debugging. End users never see numbers.

**Why this works:**
- Users don't think in percentages. They think "yes / probably / maybe / no."
- Hiding the number for the confident case stops the user from second-guessing correct predictions.
- Showing "Tap to confirm" for the uncertain case turns confidence into an *action,* not a label.

---

## 8. Implementation priority for Build 5

Ranked by user-pain-reduction-per-line-of-code:

| Priority | Change | Why first |
|---|---|---|
| **P0** | Unified `ItemThumbnailView` with `maskedImagePath ?? cutout-backfill` | Kills the source-photo backdrop bug class everywhere at once; <200 LOC |
| **P0** | White-bg, aspect-fit grid card with 16pt padding | Single biggest visual-quality lift; 1 file |
| **P0** | Editorial single-hero color (skin-tone suppression + Lab merging) | Fixes "5 shades of blue" + "0%" + skin-tone-leak in one shot |
| **P0** | Hide numeric confidence; auto-expand low-conf items only | Removes 80% of form burden in one render-time decision |
| **P1** | Review wall replacing 6× ItemFormView loop | The big architecture move; the right time to ship is right after the P0 rendering changes land |
| **P1** | `WornOutfit` table + sub-tab + auto-create-on-batch | New first-class entity; ship the migration + timeline view together |
| **P1** | Texture: top-3 inline + "Other…" sheet | Small surgical change to existing form |
| **P2** | Subcategory combobox (search + recents) | Quality-of-life; can ship after the structural changes |
| **P2** | "Tap to confirm" inline category fix on review wall | Final polish on review flow |
| **P3** | Calendar view of WornOutfits | Defer until timeline has data |

P0 blocks the next TestFlight. P1 is the marquee Build-5 feature. P2/P3 are post-launch iterations.

---

## 9. What NOT to build in Build 5

A senior designer's job is also to delete scope. Defer or kill:

- **Layered-look hint** (`shouldShowLayeredLookHint` in `MultiGarmentGridView`). Useful, but the new review wall makes layered detection a soft warning instead of a banner. Migrate the heuristic, kill the standalone UI.
- **Bbox overlay on detail view** (PR #21). Move this to a "View in source photo" affordance inside `WornOutfitDetailView`. The wardrobe item's detail view should lead with the cutout, not the source.
- **"Save & add another garment" button** (`canShowAddAnother` in AddItemView). Replaced by multi-pick → review wall. The single-photo-multiple-garments flow is the dominant use case now; the loop affordance is a relic.
- **Per-item progress bar in the form** (`batchProgressBar`). Replaced by the review wall's overview — 6 cards visible at once is the progress bar.
- **Sparkles auto-detected badge** on individual sections. Replaced by review-wall expansion logic — if a row is expanded, the user knows the model needs help; if it's collapsed, the model's confident.

---

## 10. Closing opinion

The current app is a CRUD form for a wardrobe table. The app the user wants is a *wardrobe* — a place where outfits live as moments and items live as objects, where the AI's job is to be quietly competent and stay out of the way unless asked. Build 4 surfaces too much engineering and asks the user to do too much labor. Build 5's job is to **collapse the form into a confidence-triaged review, standardize every place an item is rendered into one component on white, and promote "what I wore today" into a first-class entity.** Everything else follows from those three.

If you ship only one thing this build, ship the unified `ItemThumbnailView`. It deletes a class of bugs and makes the app look 50% more finished overnight. If you ship two, add the editorial single-hero color. If you ship three, add the review wall. The rest can follow.

— End of critique.
