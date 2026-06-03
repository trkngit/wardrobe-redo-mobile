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
    /// Confidence stamped on rules-derived textures. Build 47 — bumped
    /// 0.85 → 0.95 to stay above the raised `AttributePrefill.minConfidence`
    /// (now 0.90). This is a DETERMINISTIC mapping (jeans → denim,
    /// sweater → knit), not a probabilistic guess, so it legitimately
    /// belongs above the gate — the bar was raised to suppress unreliable
    /// ML category guesses, not to suppress reliable rules. The 0.95
    /// sentinel keeps rules textures pre-filling while staying clearly
    /// distinguishable from a real ML score in the `detected_attributes`
    /// JSONB telemetry.
    static let rulesTextureConfidence: Float = 0.95

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

    /// Stop-gap texture inference until the v1.1 attribute classifier
    /// ships a real texture head. Returns a `TextureType` only when the
    /// subcategory commits unambiguously to a fabric (jeans → denim,
    /// sweater → knit, hoodie → fleece, …) OR when the category has a
    /// safe default (bottom → denim — see `RulesTable.categoryDefaultTexture`).
    /// Returns `nil` only when neither rule fires.
    ///
    /// **Lookup order (added in PR #25, build 5):**
    /// 1. Subcategory-keyed rule (`RulesTable.texture(for: subcategory)`).
    ///    Wins when the subcategory commits to a fabric (e.g. `.jeans → .denim`).
    /// 2. Category-default rule (`RulesTable.categoryDefaultTexture(for: category)`).
    ///    Catches the build-4 dogfood case where the upstream classifier
    ///    misclassified jeans as `.shorts` — the subcategory rule misses
    ///    (`.shorts` has no fabric default, correctly), but the category
    ///    rule rescues `.bottom → .denim`.
    ///
    /// - Parameters:
    ///   - category: the final `ClothingCategory` for the proposal.
    ///     Used as the second-tier fallback when the subcategory rule
    ///     returns nil.
    ///   - subcategory: the final `ClothingSubcategory`. Tried first.
    static func deriveTexture(
        category: ClothingCategory,
        subcategory: ClothingSubcategory
    ) -> TextureType? {
        if let subcategoryTexture = RulesTable.texture(for: subcategory) {
            return subcategoryTexture
        }
        return RulesTable.categoryDefaultTexture(for: category)
    }
}
