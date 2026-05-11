# Build 6 — Manual Test Plan

End-to-end verification of every user-visible change shipped in
build 6 (PR #38). Walk through this on a real iPhone after the
prerequisites are met. Marks pass/fail as you go.

---

## Phase A — Prerequisites (one-time setup)

Done in this order. Each step blocks everything after it.

### A1. Apply the three new Supabase migrations

Three migrations land in this build: a wear-count RPC, the
`profiles.default_vibe` column, and the
`wardrobe_items.silhouette_area` column. The iOS client writes
to all three the moment it runs, so they must land **before**
you install build 9.

**Easiest path — Supabase dashboard SQL editor:**

1. Open https://app.supabase.com → your project → SQL Editor.
2. Open a new query.
3. Copy/paste the body of `supabase/migrations/00014_wardrobe_items_wear_count_rpc.sql`, click Run. Confirm no error.
4. Repeat for `00015_profiles_default_vibe.sql`.
5. Repeat for `00016_wardrobe_items_silhouette_area.sql`.

All three use `CREATE OR REPLACE` or `ADD COLUMN IF NOT EXISTS`,
so re-running is safe.

**CLI path (if you prefer):**

```
cd "/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/.claude/worktrees/gifted-moore-634d71/supabase"
supabase login                   # opens browser if not already logged in
supabase link --project-ref <your-project-ref>
supabase db push
```

**Verify in dashboard → Database → Tables:**

- [ ] `profiles` has a `default_vibe` column (text, default
      `'balanced'`, CHECK constraint with 5 enum values).
- [ ] `wardrobe_items` has a `silhouette_area` column (double
      precision, nullable, CHECK 0..1).
- [ ] Database → Functions shows
      `wardrobe_items_increment_wear_count(uuid[])` listed as a
      `security definer` function.

### A2. Install build 9 on your device

Pick whichever you've used before:

- **TestFlight (recommended)** — wait for the build to process
  (~10-15 min after upload), accept the invite, install.
- **Xcode direct install** — connect the device, open the
  project, select your device as the run target, hit ⌘R. This
  works without any TestFlight upload at all and is the
  fastest path if you're testing on your own iPhone.

### A3. Sign in

- [ ] Sign in with your existing account, OR
- [ ] Sign up fresh — required if you want to exercise
      onboarding (§D1 below).

### A4. (Optional) Reset camera permission

Run this before §B if you want to verify the cold-launch
shutter from a never-granted-permission state:

- iOS Settings → General → Transfer or Reset iPhone → Reset →
  Reset Location & Privacy. **Or** delete the app and reinstall.

This is the only way to exercise the new `.starting` overlay
("Starting camera…") without a hardware reset.

---

## Phase B — Camera flow (Phase 1)

### B1. Cold-launch shutter works

1. Cold-launch the app (kill from app switcher first).
2. Sign in.
3. Tap "+" → "Take Photo".
4. Watch for the `.starting` overlay if permission was not
   previously granted: **a `ProgressView()` spinner + "Starting
   camera…" copy.** This is new in build 6 — pre-build-6 the
   button just looked dead during permission resolution.
5. After permission grants and the session starts, the live
   preview appears.
6. Tap the shutter button.

- [ ] Spinner + "Starting camera…" visible during permission flight
      (only if A4 was done)
- [ ] Shutter button lights up once the session is running
- [ ] Tapping the shutter triggers a medium-impact haptic
      **immediately on tap** (before the photo flash)
- [ ] The button visibly scales down ~8% on press (spring
      animation, ~180 ms)
- [ ] Photo captures successfully and the touchup screen opens

### B2. Green border in good conditions

1. With the camera open, point at a plain wall in good light.
2. Hold steady for ≥0.5 seconds.

- [ ] A 3-px green stroke appears around the preview rect
- [ ] Quality pill reads "Looks great — hold still"
- [ ] Coaching text reads "Place clothing on a clean, flat
      surface" (always visible in `.live` and `.preparing` phases)

### B3. Green border NOT required for capture

1. Aim at a messy room or a person.
2. Quality pill should turn yellow + show coaching like "Too
   busy — try a plainer background."

- [ ] No green border visible
- [ ] Shutter still works (we coach, we don't gatekeep)

### B4. Capture failure surfaces an error

This is hard to force on a normal device, but the path exists:
if `PhotoCaptureDelegate.photoOutput(...didFinishProcessingPhoto:error:)`
fires with an error, `viewModel.errorMessage` is set and the
banner appears. Verify by inducing a low-memory state if
possible, OR just trust that the path is now wired (vs.
swallowed silently in build 5).

- [ ] (Optional) Capture failure shows "Couldn't capture: …"
      banner

### B5. Background/foreground transitions are clean

1. Open camera screen.
2. Send the app to background (swipe up, or press the home/lock).
3. Re-foreground after ~5 seconds.

- [ ] Camera preview resumes without crashing
- [ ] No flicker or stale-frame artifact

---

## Phase C — Auto-detection scope (Phase 2)

### C1. Texture auto-fills for items with a rule

1. Add a pair of jeans (Take Photo or Choose from Library).
2. Watch the details screen.

- [ ] Subcategory pre-fills as `Jeans`
- [ ] **Texture pre-fills as `Denim`** (via the rules-engine
      lookup — no ML inference involved)
- [ ] Color extraction populates dominant colors
- [ ] Category pre-fills as `Bottom`

Repeat with a sweater → expect texture = `Knit`.

### C2. Texture stays blank for ambiguous items

1. Add a plain T-shirt.

- [ ] Subcategory pre-fills as `T-Shirt`
- [ ] **Texture picker stays empty** — the rules engine doesn't
      commit to fabric for ambiguous subcategories
- [ ] You can manually pick `Cotton` (or whatever) from the
      picker
- [ ] Saving without a texture works fine (the item still saves)

### C3. Confirm Supabase row

Open Supabase → Table editor → wardrobe_items → newest row:

- [ ] `texture` is `'denim'` for the jeans, NULL for the T-shirt
- [ ] `silhouette_area` is a value in (0, 1] — new in build 6
- [ ] `bounding_box` populates for multi-pick captures (existing
      behavior)

---

## Phase D — Vibe slider (Phase 6 + follow-ups)

### D1. Onboarding asks for a vibe (fresh sign-up only)

If you signed up fresh in §A3:

1. After the style preferences step, you should see a new step
   3 of 5: "Pick your default vibe."

- [ ] Step 3 reads "Pick your default vibe"
- [ ] A 5-stop pill control shows: Safe, Polished, Balanced,
      Adventurous, Bold
- [ ] A descriptive card below updates as you tap each pill
      (e.g., "Maximum convention" for Safe, "Break the rules"
      for Bold)
- [ ] Default selection is Balanced
- [ ] Completing onboarding writes your pick to
      `profiles.default_vibe`

### D2. Settings has a default-vibe row

1. Open Profile → look for the new section "Default vibe."
2. The current value should match whatever you picked at
   onboarding (or `balanced` if you skipped it).

- [ ] The section title reads "Default vibe"
- [ ] Help text reads "Where every outfit-generation session
      starts. You can still slide between Safe and Bold on the
      Outfits screen."
- [ ] Tapping a different pill updates the row immediately
      (optimistic UI)
- [ ] Closing + reopening the app re-loads the same vibe
- [ ] Verify in Supabase: `profiles.default_vibe` matches your
      pick

### D3. Outfits tab vibe slider

1. Go to Outfits → today's outfits view.
2. Verify the new `VibeSelector` lives between the occasion
   picker and the Generate button.

- [ ] Slider seeds from your stored default
- [ ] Tagline below the pills updates per stop
- [ ] Tap "Generate New Outfits" with Bold → outfits skew
      toward novel pairings + more color families
- [ ] Tap "Generate New Outfits" with Safe → outfits skew
      toward classic, tighter palettes
- [ ] The top-ranked outfit visibly differs between Safe and
      Bold runs on the same wardrobe

### D4. Match tab vibe slider

1. Go to Match → pick a hero item.
2. Wait for the 5 match results to load.
3. Slide the vibe pill.

- [ ] Slider visible above the occasion picker
- [ ] Sliding from Balanced → Bold re-runs the match (loading
      state shows briefly, then results re-rank)
- [ ] The reasoning text on the score breakdown reflects the
      new vibe (e.g., color-cap mentions are higher under Bold)

---

## Phase E — Engine improvements (Phases 3, 5, 7, 8)

### E1. Wear-count increments on "I wore this"

1. Open Outfits → tap an outfit → tap "I wore this" (heart).
2. Wait 2-3 seconds for the RPC.
3. Verify in Supabase → Table editor → wardrobe_items → look
   at every item in that outfit:

- [ ] `wear_count` is +1 from before the tap
- [ ] `last_worn_at` is `now()`
- [ ] Toggling un-worn → worn → un-worn does NOT bump the
      count again (wear is monotonic; the second toggle is a no-op)

### E2. Novelty bonus produces different outfits

1. On Outfits, tap Generate New Outfits.
2. Note the top outfit's editorial name.
3. Tap Generate New Outfits again (re-rolls with a fresh seed).

- [ ] The two runs produce **different** top outfits when there's
      enough wardrobe variety (the novelty bonus discounts pairs
      seen in your last 30 saved outfits)
- [ ] If your wardrobe has fewer than 5 items the runs may
      look similar — that's expected (small candidate space)

### E3. Coverage-aware "Insufficient data" surfaces

1. Add a brand-new minimal wardrobe (3 items: top, bottom,
   shoes) where 2 of them have **no** fit attribute and **no**
   texture set.
2. Generate today's outfits.
3. Open the outfit detail → score breakdown.

- [ ] At least one outfit reads as "Insufficient data" (low
      coverage flag fires when < 4 of 7 dimensions have data)
- [ ] Other outfits — where 4+ dimensions covered — show a
      numeric score normally
- [ ] No outfit shows a flat 0.5 fallback for a dimension that
      genuinely had no input (the dimension is excluded
      entirely)

### E4. Color-harmony reasoning shows area-weighted percentages

1. Add a plain black top + plain white pants (or use existing
   items).
2. Generate an outfit containing both.
3. Open the outfit detail → tap on the Color dimension to see
   the reasoning text.

- [ ] The dominant percentage reads **47% or 53%** (≈ 0.28 /
      0.32 silhouette weights), **not 50%** — that's the
      pre-build-6 item-count fallacy
- [ ] An outfit with a dress + a belt should read the dress
      color as dominating (high silhouette weight)

### E5. Formality reasoning lists 4 components

1. Open any outfit's score breakdown.
2. Find the Formality dimension's reasoning text.

- [ ] The text references multiple of: texture smoothness,
      color brightness, pattern, structure (rather than a
      single texture-only descriptor)

### E6. OutfitFormula reasoning cites Bornstein / Gunn

1. Same outfit detail → Formula dimension reasoning text.

- [ ] Mentions "Hero piece" (Bornstein) and/or "Third piece"
      (Gunn) by name when those components fire

---

## Phase F — Memory + smoothness (Phase 4)

Hard to measure precisely without Instruments; the qualitative
check: rapid open/close should feel smooth, not laggy.

### F1. Rapid Add-Item open/close

1. Open the Add Item sheet, take a photo, save it.
2. Repeat 10 times quickly.

- [ ] App doesn't slow down or grow visibly sluggish
- [ ] No "memory warning" toast or thermal throttling
- [ ] Camera screen opens within ~1 s every time (no
      compounding latency)

### F2. Camera teardown

1. Open camera, take a photo, return to Add Item.
2. Look at the iOS status bar.

- [ ] No persistent orange "camera in use" dot after returning
      from camera (would indicate the AVCaptureSession is
      lingering)

---

## Phase G — Regressions to check

Make sure build 6 didn't break anything that worked before.

### G1. Existing wardrobe items load

- [ ] Existing items (saved before build 6) load with all
      their fields intact
- [ ] Their `silhouette_area` is null but the engine still
      scores them via the category-default fallback
- [ ] Their `default_vibe` is `'balanced'` if the column was
      added by migration default

### G2. Existing onboarding state

- [ ] If you completed onboarding pre-build-6, you don't see
      onboarding again
- [ ] If you sign out + back in, you don't see onboarding

### G3. Outfit history loads

- [ ] Past saved outfits visible in their respective dates
- [ ] Score breakdowns load (legacy JSON decodes correctly via
      the `decodeIfPresent ?? 1.0` coverage fallback)

### G4. Multi-garment capture still works

- [ ] Take a wide photo with 2-3 garments visible
- [ ] Multi-pick grid surfaces correctly
- [ ] Each garment saves with its own bbox + silhouette_area

---

## What to do if a check fails

- **Photograph the failure** — screenshot or short screen
  recording.
- **Note which check failed by ID** (e.g., "D3 — slider didn't
  re-rank").
- **Note Supabase row state if relevant** — for engine checks,
  the row data + the visible reasoning text together pin the
  cause.

Then add a comment on PR #38 with the check ID + evidence,
and we'll triage from there.

---

## Quick sanity-check matrix

A 5-minute version if you want to spot-check before doing the
full walkthrough:

| Check | Time | Pass criteria |
|---|---|---|
| B1 cold-launch shutter | 1 min | Spinner → shutter lights up → haptic on tap → photo saves |
| C1 jeans texture rule | 1 min | Add jeans → texture pre-fills `Denim` |
| D3 Outfits vibe slider | 2 min | Bold vs Safe produces different top outfit |
| E1 wear count | 1 min | Tap "I wore this" → Supabase wear_count +1 |

If all four pass, the build is functionally healthy. The
remaining checks cover edge cases + verify the engine's
internal reasoning quality.
