import Foundation

/// Deterministic rules engine that derives `(Set<Season>, Set<Occasion>)`
/// from a predicted `(ClothingCategory, ClothingSubcategory, TextureType?)`
/// triple.
///
/// Why rules, not a second classifier:
///   Season and occasion are almost entirely derivable from the category
///   + texture we already predict. Training a second model would burn
///   pod-hours for a tiny gain, and rules are introspectable — we can
///   show the user exactly why a sundress got pre-filled as
///   `[.spring, .summer]`.
///
/// Invariant:
///   Both returned sets are **always non-empty**. If no rule matches,
///   the fallback is `Season.allCases` / `[.casual]` so the picker on
///   the Add Item form never lands on zero selections.
///
/// The rules themselves live in `RulesTable.swift` — this file just wires
/// the entry point and enforces the non-empty invariant.
///
/// See docs/plans/2026-04-19-auto-attribute-detection.md Phase 5 +
/// docs/plans/2026-04-19-auto-attribute-detection/RULES_TABLE.md for the
/// reviewable rules source.
enum AttributeRulesEngine {
    /// Derive season + occasion pre-fills from a predicted triple.
    ///
    /// - Parameters:
    ///   - category: the final `ClothingCategory` chosen for the item
    ///     (post-threshold). Must be non-nil by contract — callers should
    ///     fall back to the subcategory's `.category` before calling here.
    ///   - subcategory: the final `ClothingSubcategory`. Callers should
    ///     already have resolved the category-default when the predicted
    ///     subcategory was missing or mismatched.
    ///   - texture: predicted texture, or `nil` when the confidence was
    ///     below the threshold. Rules that key on a specific texture
    ///     simply won't match; category-level defaults will catch them.
    /// - Returns: Non-empty season and occasion sets suitable for seeding
    ///   the Add Item form pickers.
    static func derive(
        category: ClothingCategory,
        subcategory: ClothingSubcategory,
        texture: TextureType?
    ) -> (seasons: Set<Season>, occasions: Set<Occasion>) {
        let seasons = RulesTable.seasons(for: category, subcategory: subcategory, texture: texture)
        let occasions = RulesTable.occasions(for: category, subcategory: subcategory, texture: texture)
        // Invariant enforcement: never return an empty set. The rules
        // table is supposed to cover every case, but a defensive fallback
        // is cheaper than a crash.
        return (
            seasons.isEmpty ? Set(Season.allCases) : seasons,
            occasions.isEmpty ? [.casual] : occasions
        )
    }
}
