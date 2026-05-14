# Build 18 — UI / code audit + fixes

## Goal

User report: "check for ui components and how they would look — buttons,
newlines, scrollables, image opening when clicked on a uploaded item.
check for code errors what could bug. create a plan to look through each
and every possible screen of the app."

This is a structured audit pass. The plan enumerates every screen,
lists the SwiftUI footguns to check against each one, executes the
audit, and ships fixes for whatever turns up.

## Every screen / sheet in the app

Found by listing `WardrobeReDo/Views/**/*.swift`:

### Tab roots (4)
1. **WardrobeGridView** — tab 0, primary entry to inventory
2. **DailyOutfitsView** — tab 1, today's outfits carousel
3. **MatchingView** — tab 2, hero-piece matching
4. **ProfileView** — tab 3, user info, settings, sign out

### Wardrobe stack
5. **ItemDetailView** — push from any item card
6. **ItemFormView** — embedded in AddItemView + EditItemView
7. **AddItemView** — sheet from Wardrobe `+` toolbar button
8. **EditItemView** — sheet from ItemDetailView edit button
9. **FirstRunTutorialView** — full-screen on first launch after sign-up
10. **AnalyzingPopup** — overlay during background analysis

### Outfit stack
11. **OutfitDetailView** — push from a carousel card
12. **OutfitCardView** — embedded in the carousel
13. **MatchResultCard** — embedded in the Match results list

### Profile stack
14. **StylePreferencesEditor** — sheet from Profile preferences row
15. **DeveloperMenuView** — push, DEBUG-only
16. **MLDiagnosticsView** — push from DeveloperMenu, DEBUG-only

### Auth + onboarding
17. **LoginView** — full-screen when unauthenticated
18. **OnboardingView** — full-screen for new sign-ups

### Camera + extraction
19. **CameraCaptureView** — full-screen sheet from AddItem
20. **CameraOverlay** — embedded in CameraCaptureView
21. **MultiGarmentGridView** — embedded in AddItem after multi-detect
22. **TapToSelectView** — embedded in AddItem for manual SAM2
23. **MaskTouchupView** — push from AddItem mask preview

### Reusable components (rendered inside multiple screens above)
24. **GoldButton / GhostButton** — primary / secondary CTAs
25. **VibeSelector** — pill row, used in Outfits / Match / Profile
26. **ItemCardView** — wardrobe grid cell
27. **ItemThumbnailView** — image-loading core for cards
28. **ColorSwatchView / EditorialColorView** — color palette
29. **EditorialTextField** — used on Login + Profile sign-in
30. **ShimmerPlaceholders** — skeleton loading states
31. **StatusToast** — post-action confirmation
32. **AnimationModifiers** — staggered fade-in helpers

## Checklist applied to each screen

For every screen we evaluate against this list. The shipped audit
record (next section) calls out only the screens where a check failed.

1. **Tap targets ≥ 44 × 44pt** — every interactive element large
   enough for a fingertip on the smallest supported device (SE).
2. **Long-text overflow** — labels that can hold long content (item
   names, occasion + vibe in toasts, Turkish translations longer
   than English) have `lineLimit` + `minimumScaleFactor` set OR are
   inside a scrollable / wrapping container.
3. **Image tap behavior** — primary item images open a fullscreen
   viewer with pinch-to-zoom + swipe-to-dismiss. User flagged this
   as the headline issue.
4. **ScrollView contention** — no nested ScrollViews on the same
   axis; no ScrollView inside `List`; LazyVStack/VGrid only inside
   a ScrollView, not standalone.
5. **Safe area** — content under nav bar / tab bar / home indicator
   uses `.ignoresSafeArea(.container, edges: …)` only when intended;
   nothing is silently clipped.
6. **Keyboard avoidance** — every TextField sits inside a scrollable
   container or has explicit `.scrollDismissesKeyboard(.interactively)`.
7. **NavigationLink consistency** — value-based `NavigationLink(value:)`
   plus `navigationDestination(for:)`, OR explicit `NavigationLink {
   destination } label:`. No deprecated `NavigationLink(destination:)`
   constructor in new code.
8. **Async cancellation** — every long-running Task that touches the
   view's lifetime captures `[weak self]` (for VMs) or is cancelled
   in `onDisappear`. We already verified this for the regeneration
   task in Build 7; audit covers the rest.
9. **Background → main hops** — UI state writes happen on the main
   actor; data fetches don't block main.
10. **Animation key correctness** — `.animation(_:value:)` is keyed
    on the actual state that should drive the transition, not a
    derived value that mutates on every render.
11. **Sheet / fullScreenCover lifecycle** — `onDismiss` cleans up
    any temporary state so re-opening starts fresh.
12. **Accessibility traits** — interactive elements have `.isButton`
    or `.isSelected` traits when the visual cue is non-obvious.
13. **Localized helper signatures** — chip helpers + section headers
    take `LocalizedStringResource`, not `String`, so the String
    Catalog path stays unbroken (followed up in Build 17).

## Findings (Build 18)

### Critical
- **ItemDetailView image is not tappable.** No `Button`, no
  `onTapGesture` wraps the `KFImage` — user-flagged. Fix: add a
  fullscreen image viewer with pinch-to-zoom + swipe-to-dismiss.

### High
- **No reusable fullscreen image viewer component exists.** Need to
  build `FullScreenImageViewer` as a `Components/` module. Will be
  used by the wardrobe item detail and (eventually) the outfit
  detail item gallery.

### Medium
- **Long subcategory names overflow `ItemCardView` badge.** "Designer
  Sneakers" / "Tasarımcı Sneaker" are wide; the `.ultraThinMaterial`
  Capsule has no `lineLimit`. Verify and add `lineLimit(1)` +
  `minimumScaleFactor(0.85)`.
- **OutfitCardView title `lineLimit(1)`** is correct, but the
  editorial description on smaller phones can wrap to 3 lines in
  Turkish ("Polished classics" → "Şık klasikler" is OK, but
  "Adventurous mix" → "Cesur karışım" plus a leading article can
  push). Already has `lineLimit(2)`, verify.
- **StatusToast `lineLimit(1)` + `minimumScaleFactor(0.85)`** —
  the Build 7 toast template "Updated for [Occasion] · [Vibe]"
  becomes "%@ · %@ için güncellendi" in Turkish. Worst case
  "Athletic · Adventurous" → "Spor · Cesur için güncellendi" —
  fits, but pinned this to verify in the audit.

### Low
- **ItemFormView seasons row is a fixed `HStack`** with 4 chips.
  Turkish season names ("İlkbahar" / "Sonbahar") are longer; on
  iPhone SE the row may overflow horizontally. Switch to
  `FlowLayout` / `LazyVGrid` to wrap when needed.
- **Match tab "Surprise me" button** uses GoldButton's `frame(height: 48)`
  which is fine, but the loading title "Karıştırılıyor…" plus the
  spinner may push tight on iPhone SE. Already has `minimumScaleFactor`
  inherited from text — verify.

## Phases

### Phase 1 — `FullScreenImageViewer` component
New file `WardrobeReDo/Views/Components/FullScreenImageViewer.swift`.
Uses `MagnificationGesture` + `DragGesture` for pinch-to-zoom and
swipe-down-to-dismiss. Wrapped in `.fullScreenCover(isPresented:)`
so the system handles the dismissal animation.

### Phase 2 — Wire ItemDetailView image to the viewer
Wrap the `imageSection` GeometryReader in a `Button` whose action
flips a `@State private var showFullScreenImage = false` flag, then
mount the viewer via `.fullScreenCover(isPresented:)` on the
parent.

### Phase 3 — Overflow fixes
- ItemCardView badge: add `lineLimit(1)` + `minimumScaleFactor(0.85)`.
- ItemFormView seasons section: switch HStack to LazyVGrid with
  `.adaptive(minimum: 80)`.

### Phase 4 — Accessibility / minor
- Image button has `accessibilityLabel("View item photo full screen")`
  and `accessibilityHint("Double-tap to enlarge")`.
- Catalog entries for the new strings.

### Phase 5 — Tests + Fast plan + ship build 22
- Smoke-test new fullscreen viewer behavior is testable via the
  `.fullScreenCover` binding (no UI assertion needed).
- Run Fast plan to confirm no regressions.
- Bump CFBundleVersion to 22, archive + upload.

## Out of scope (deferred to Build 19+)

- Multi-image gallery on OutfitDetail (would need pinch + paging)
- Animated heart on react love (delight, not function)
- Pull-to-refresh haptics across Wardrobe / Outfits / Match (we
  already have refresh; haptic on completion is polish)
- Full a11y audit (we did a partial pass in Build 8; full AA audit
  with VoiceOver routing is its own initiative)
- iPad layout — TARGETED_DEVICE_FAMILY is "1" (iPhone only)

## Risks

| Risk | Mitigation |
|---|---|
| Image viewer eats system gestures | Use `.fullScreenCover` so the system dismissal animation runs alongside our swipe-down gesture rather than competing with it. |
| Pinch zoom feels janky | Use `MagnificationGesture` with a multiplicative state so the next pinch starts from the prior scale, not from 1.0. |
| Tap-to-open conflicts with the existing bounding-box highlight | The highlight is `.allowsHitTesting(false)` so the underlying Button receives the tap. |
| Long localized strings overflow on iPhone SE | Audit Phase 3 + `minimumScaleFactor(0.85)` provide a safety net. |
