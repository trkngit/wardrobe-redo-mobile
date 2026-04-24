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

            Picker("Category", selection: $category) {
                ForEach(ClothingCategory.allCases, id: \.self) { cat in
                    Text(cat.displayName).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: category) {
                onCategoryChanged()
            }

            Picker("Subcategory", selection: $subcategory) {
                ForEach(availableSubcategories, id: \.self) { sub in
                    Text(sub.displayName).tag(sub)
                }
            }
            .pickerStyle(.menu)
            .tint(Color(Theme.Colors.primary))
        }
    }

    private var textureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Texture", auto: isSectionAutoDetected(.texture))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: Theme.Spacing.sm) {
                ForEach(TextureType.allCases, id: \.self) { tex in
                    chipButton(
                        tex.displayName,
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

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(FitAttribute.allCases, id: \.self) { fit in
                    chipButton(
                        fit.displayName,
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

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Season.allCases, id: \.self) { season in
                    chipButton(
                        season.displayName,
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
                        occasion.displayName,
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
    private func sectionHeader(_ title: String, auto: Bool) -> some View {
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

    private func chipButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
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
