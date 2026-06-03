import SwiftUI

/// Shared SwiftUI form body for the six user-editable attributes of a
/// wardrobe item: category, subcategory, texture, fit, seasons, and
/// occasions.
///
/// ## Why a shared component
/// - `AddItemView` renders the same fields during its "details" step.
/// - `EditItemView` (Phase 5) renders them to let users correct an ML
///   mistake or add a texture they never got around to.
///
/// Rather than duplicate ~150 lines of SwiftUI between the two, this
/// view takes `@Binding`s and drives the shared subset. Call sites that
/// need extras (Add's image preview + colour swatches + save actions;
/// Edit's "this is read-only" photo hero) compose this view inside
/// their own layouts.
///
/// ## What's intentionally NOT here
/// - Image preview / colour swatch display — owned by the caller.
/// - Save / Cancel buttons — each surface has its own affordance pattern
///   (Add has multi-pick + "save & add another"; Edit is a simple pair).
/// - Auto-detected "sparkle" badges — hook for those is provided via
///   `isSectionAutoDetected` so the Add form can light them up without
///   the Edit form carrying the concept at all.
///
/// ## Availability subset
/// `availableSubcategories` is supplied by the caller because the valid
/// subset for a given `ClothingCategory` is owned by
/// `ClothingSubcategory.subcategories(for:)` — a domain helper the form
/// shouldn't know about. Passing it in keeps this view free of
/// domain-model assumptions.
struct ItemFormView: View {

    /// Identifier for each section of the form — used by the optional
    /// `isSectionAutoDetected` hook so the Add caller can flag only the
    /// sections the ML pipeline pre-filled. Extending the form with a
    /// new section means growing this enum; tests + the Add caller will
    /// both fail to compile until the new case is handled, which is
    /// exactly the drift guard we want.
    enum Section: Hashable {
        case category
        case texture
        case fit
        case seasons
        case occasions
    }

    // MARK: - Bindings

    @Binding var category: ClothingCategory
    @Binding var subcategory: ClothingSubcategory
    @Binding var texture: TextureType?
    @Binding var fitAttribute: FitAttribute?
    @Binding var selectedSeasons: Set<Season>
    @Binding var selectedOccasions: Set<Occasion>

    /// Build 47 — whether the category reflects a confirmed choice (a
    /// high-confidence ML prefill or an explicit user tap). When false,
    /// the category section shows a "Choose a category" prompt with
    /// tappable chips instead of a pre-highlighted segmented control, so
    /// the app never implies a category it didn't actually detect.
    /// The Edit screen always has a known category, so it passes
    /// `.constant(true)` and is unaffected.
    @Binding var categoryConfirmed: Bool

    // MARK: - Caller-supplied data + hooks

    /// Valid subcategories for the current `category`. The Add/Edit call
    /// sites pass `ClothingSubcategory.subcategories(for: category)` —
    /// computed live so changing `category` re-drives the picker.
    let availableSubcategories: [ClothingSubcategory]

    /// Called after the user picks a new category. Callers typically use
    /// this to clamp `subcategory` into the new valid subset (Add's VM
    /// has exactly this logic in `onCategoryChanged`).
    var onCategoryChanged: () -> Void = {}

    /// Whether a given section was auto-detected by the ML pipeline.
    /// Default returns false for every section, which is the Edit-mode
    /// behaviour. AddItemView passes a closure that compares the live
    /// form value to the snapshot recorded at pre-fill time and lights
    /// up a sparkle badge while they still match.
    var isSectionAutoDetected: (Section) -> Bool = { _ in false }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            categorySection
            textureSection
            fitSection
            seasonsSection
            occasionsSection
        }
    }

    // MARK: - Sections

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Category", auto: isSectionAutoDetected(.category))

            if categoryConfirmed {
                // Build 48 — category as a wrapping chip grid instead of
                // a segmented control. The segmented control truncated
                // the longer localized labels ("Outer…", "Acces…", and
                // Turkish equivalents are longer still), making it hard to
                // see all six options (the "make categories easier to
                // find" request). Chips wrap, never truncate, and match
                // the texture/fit/seasons/occasions controls below — so
                // Dress and every category are always fully legible. The
                // selected category is highlighted; tapping another sets
                // it (and reconfirms via onCategoryChanged).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: Theme.Spacing.sm) {
                    ForEach(ClothingCategory.allCases, id: \.self) { cat in
                        chipButton(cat.localizedName, isSelected: category == cat) {
                            category = cat
                            onCategoryChanged()
                        }
                    }
                }

                Picker("Subcategory", selection: $subcategory) {
                    ForEach(availableSubcategories, id: \.self) { sub in
                        Text(sub.localizedName).tag(sub)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color(Theme.Colors.primary))
            } else {
                // Build 47 — unconfirmed: the ML wasn't confident enough
                // to claim a category, so we don't pre-highlight one.
                // The user taps a chip to choose; that flips
                // `categoryConfirmed` true (via onCategoryChanged on the
                // VM) and the view swaps to the segmented control above.
                // A non-segmented chip row is used precisely BECAUSE a
                // segmented control always shows one selection — which
                // would imply a guess we don't want to make.
                Text("Choose a category")
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: Theme.Spacing.sm) {
                    ForEach(ClothingCategory.allCases, id: \.self) { cat in
                        chipButton(cat.localizedName, isSelected: false) {
                            category = cat
                            categoryConfirmed = true
                            onCategoryChanged()
                        }
                    }
                }
            }
        }
    }

    private var textureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Texture", auto: isSectionAutoDetected(.texture))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                ForEach(TextureType.allCases, id: \.self) { tex in
                    chipButton(
                        tex.localizedName,
                        isSelected: texture == tex
                    ) {
                        texture = (texture == tex) ? nil : tex
                    }
                }
            }
        }
    }

    private var fitSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Fit", auto: isSectionAutoDetected(.fit))

            // Build 18 — same adaptive grid swap as seasons: 6 fits
            // × Turkish ("Yapılandırılmış" is 16 characters) blow
            // past the iPhone SE width otherwise.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                ForEach(FitAttribute.allCases, id: \.self) { fit in
                    chipButton(
                        fit.localizedName,
                        isSelected: fitAttribute == fit
                    ) {
                        fitAttribute = (fitAttribute == fit) ? nil : fit
                    }
                }
            }
        }
    }

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Seasons", auto: isSectionAutoDetected(.seasons))

            // Build 18 — switched from fixed HStack to an adaptive
            // LazyVGrid because Turkish season names ("İlkbahar",
            // "Sonbahar") are wider than English equivalents and
            // overflow the row on iPhone SE. The grid wraps to two
            // rows when needed and packs back to one on a wider phone.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                ForEach(Season.allCases, id: \.self) { season in
                    chipButton(
                        season.localizedName,
                        isSelected: selectedSeasons.contains(season)
                    ) {
                        if selectedSeasons.contains(season) {
                            selectedSeasons.remove(season)
                        } else {
                            selectedSeasons.insert(season)
                        }
                    }
                }
            }
        }
    }

    private var occasionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Occasions", auto: isSectionAutoDetected(.occasions))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                ForEach(Occasion.allCases, id: \.self) { occasion in
                    chipButton(
                        occasion.localizedName,
                        isSelected: selectedOccasions.contains(occasion)
                    ) {
                        if selectedOccasions.contains(occasion) {
                            selectedOccasions.remove(occasion)
                        } else {
                            selectedOccasions.insert(occasion)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Section header. Lights up a sparkle badge when the caller signals
    /// the value was auto-detected by the attribute classifier.
    /// Build 17 — `LocalizedStringResource` argument so callers can
    /// pass enum-derived `localizedName` directly. The plain-string
    /// overload below stays for headers that are statically labeled
    /// at the catalog key level ("Category", "Texture", …).
    private func sectionHeader(_ title: LocalizedStringResource, auto: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.h3)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
            if auto {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(Theme.Colors.primary))
                    .accessibilityLabel("Auto-detected")
            }
        }
    }

    /// Build 17 — same LocalizedStringResource pattern as the
    /// match-tab chip helper.
    private func chipButton(_ title: LocalizedStringResource, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(isSelected ? .white : Color(Theme.Colors.textPrimary))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(isSelected ? Color(Theme.Colors.primary) : Color(Theme.Colors.surface))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .stroke(isSelected ? Color.clear : Color(Theme.Colors.border), lineWidth: 1)
                )
        }
    }
}
