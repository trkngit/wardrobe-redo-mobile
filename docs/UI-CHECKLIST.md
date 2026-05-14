# UI ship checklist

Pre-flight protocol for every new view and every TestFlight ship.
Established in Build 27 after a chain of localization + layout
regressions revealed that catching these per-screen rather than
per-symptom is the only way to ship cleanly.

## Per-screen checklist

For each `.swift` file under `WardrobeReDo/Views/`, before shipping:

### Localization
- [ ] Every `Text(_:)` call site uses **either** a string literal
      (which routes through the catalog via
      `Text(_ key: LocalizedStringKey)`) **or** a
      `LocalizedStringResource`. **Never** `Text(varName)` where
      `varName: String` — SwiftUI picks `Text(verbatim:)` and the
      catalog is silently skipped.
- [ ] Every helper signature (`init`, `func`) that displays a
      label uses `LocalizedStringResource`, not `String`. This
      makes call-site literals coerce automatically and forbids
      accidental `String` interpolation paths.
- [ ] Every enum `.displayName` used inside a `String`
      interpolation (e.g. `"\(occasion.displayName) settings"`)
      is wrapped with `String(localized: enum.localizedName)`.
      `displayName` returns raw English; `localizedName` returns
      a `LocalizedStringResource` that resolves to the catalog
      value.
- [ ] Every new user-facing string is added to
      `WardrobeReDo/Resources/Localizable.xcstrings` with a `tr`
      translation. The `CatalogCoverageTests` CI test catches the
      type-level regression; the catalog audit catches the
      missing-translation regression.

### Layout
- [ ] Every fixed-size subview inside a flexible parent (LazyVGrid
      column, ScrollView row, HStack with Spacers) has an explicit
      `.frame(maxWidth: .infinity, alignment: .center)` (or
      `.leading` / `.trailing` if intentional). Without this the
      fixed-size view defaults to leading alignment and looks
      "stuck to the left" with empty space on the right.
- [ ] Every `GeometryReader` inside a `Button` or `ScrollView`
      has a **fixed** `.frame(height:)`, not a `.maxHeight:`.
      `GeometryReader` doesn't propose a size to its parent; in
      a non-proposing container (Button, ScrollView's inner
      VStack), `maxHeight` collapses to ~0.
- [ ] Every `KFImage` (or other resizable image) inside a flex
      container uses `.frame(maxWidth: .infinity, maxHeight:
      .infinity, alignment: .center)` after `.scaledToFit()` so
      the smaller-than-frame result centers rather than hugging
      `.topLeading`.

### Gestures
- [ ] Every horizontal `ScrollView` has
      `.scrollBounceBehavior(.basedOnSize)`. Without it, iOS 17's
      rubber-band lets users drag perpendicular to the axis and
      that motion can bubble up to outer `.refreshable`
      modifiers.
- [ ] `.refreshable {}` is **only** attached to a view tree that
      contains a single, vertical, intentional scroll target.
      Don't put `.refreshable` on a body whose only scrollable
      descendants are horizontal pickers — the gesture
      resolution is ambiguous and historically caused chip-row
      drift on the Outfits tab (fixed by removing the modifier
      entirely in Build 27).

### Accessibility
- [ ] Every icon-only `Button` / `NavigationLink` /
      `ToolbarItem` has `.accessibilityLabel("...")`. Without it
      VoiceOver reads "play, button" with no context.
- [ ] Every `.accessibilityLabel` / `.accessibilityHint` that
      interpolates a localized value uses
      `String(localized: ...)`, not raw `.displayName`.
- [ ] Every Dynamic-Type-aware font uses
      `Font.system(.body)` / `.system(.subheadline)` etc., NOT
      `.system(size: 16)`. Build 21 converted all of these but
      new fonts must follow the convention.
- [ ] Every tap target on the screen is ≥ 44 × 44 pt. Run Xcode's
      Accessibility Inspector at AX5 dynamic-type to spot
      outliers.

### Component reuse
- [ ] Before adding a new colored button, check whether
      `GoldButton` / `GhostButton` cover the case. They already
      have press-scale haptic feedback, Dynamic Type, and
      `LocalizedStringResource` titles.
- [ ] Before adding a custom haptic, route through `HapticManager`
      (Build 8) — typed for selection / impact / success / warning.
- [ ] Before adding a status banner, check whether `StatusToast`
      (Build 7) or its `.statusToast(message:)` modifier covers
      the case.

## Why this exists

Before Build 27 we shipped Builds 14–16 (Turkish localization) +
Build 17 (enum displayNames → localizedName) + Build 26 (6-bug
fix pass) without ever doing a per-screen pass. Each surface had
its own gotchas (helper signature taking String, GeometryReader
in Button, ScrollView gesture conflicts) and we kept hitting them
one at a time, surface by surface.

The checklist is short enough to scan in under five minutes per
screen but long enough to catch the eight categories of bug
above. Combined with the `CatalogCoverageTests` automated check,
it's the cheapest way to keep the codebase from regressing into
the same class of bug for the third time.
