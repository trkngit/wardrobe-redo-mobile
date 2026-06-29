import Foundation

/// Pure, shared formality computation — the single source of truth for
/// the on-device formality model. Used by:
///   • `FormalityCoherenceScorer`, as the fallback when an item has no
///     persisted `formalityComputed`, and
///   • `AddItemViewModel.save`, to compute + persist `formalityComputed`
///     and `formalityComponents` at add time (TF52) so auto-filled items
///     carry a stored formality value rather than recomputing on every
///     score.
///
/// Everything here is on the app's canonical **[0, 1]** formality scale
/// (0 = most casual, 1 = most formal), matching the bundled
/// `archetypes.json` ranges and `FormalityCoherenceScorer`'s comparisons.
/// The database's historical 0–10 `compute_formality` trigger is retired
/// in migration 00018, so this client-side formula is authoritative end
/// to end — there is no longer a server formula on a different scale to
/// disagree with.
enum FormalityFormula {
    /// Effective formality, the per-component breakdown, and a coverage
    /// fraction in [0, 1] for a single item, derived from four proxies
    /// (weights restore the behaviour ENGINE.md has always documented):
    ///
    ///   • Texture smoothness (weight 0.50) — smoother reads more formal.
    ///   • Color brightness (weight 0.20) — darker reads more formal.
    ///   • Pattern proxy (weight 0.15) — ≥3 dominant colors → patterned →
    ///     slightly less formal. Always covered (inferable from
    ///     `dominantColors.count`, even when the array is empty).
    ///   • Structure (weight 0.15) — from `fitAttribute`:
    ///     structured > slim/regular > relaxed > oversized.
    ///
    /// `coverage` is the weighted share of components whose input was
    /// actually present, so a fully-tagged item gives coverage 1.0 and a
    /// category-only item gives 0.15 (pattern alone). The returned
    /// `FormalityComponents` carries each component as a normalized [0, 1]
    /// signal for explainability — it is persisted but not read back by
    /// scoring.
    static func compute(
        category: ClothingCategory,
        texture: TextureType?,
        dominantColors: [ColorProfile],
        fitAttribute: FitAttribute?
    ) -> (value: Double, components: FormalityComponents, coverage: Double) {
        let categoryBase = categoryFormality(category)

        // Component 1 — texture smoothness (weight 0.50). `formalitySmoothness`
        // is on a 0–10 scale centered at 5; smoother → more formal.
        let textureDelta: Double
        let textureCoverage: Double
        let smoothnessSignal: Double // [0, 1]
        if let texture {
            let smoothness = texture.formalitySmoothness
            textureDelta = 0.50 * (smoothness - 5.0) * 0.03
            textureCoverage = 1.0
            smoothnessSignal = smoothness / 10.0
        } else {
            textureDelta = 0
            textureCoverage = 0
            smoothnessSignal = 0.5 // neutral midpoint when unknown
        }

        // Component 2 — color brightness (weight 0.20). Mean lightness of
        // the dominant palette; darker pushes formality up.
        let brightnessDelta: Double
        let brightnessCoverage: Double
        let avgLightness: Double // [0, 1]
        if !dominantColors.isEmpty {
            avgLightness = dominantColors
                .map(\.lightness)
                .reduce(0.0, +) / Double(dominantColors.count)
            brightnessDelta = 0.20 * (0.5 - avgLightness) * 0.4
            brightnessCoverage = 1.0
        } else {
            avgLightness = 0.5
            brightnessDelta = 0
            brightnessCoverage = 0
        }

        // Component 3 — pattern proxy (weight 0.15). ≥3 dominant color
        // clusters → likely patterned → reduce formality slightly. Always
        // covered (an empty palette reads as "solid, no pattern").
        let isPatterned = dominantColors.count >= 3
        let patternDelta = isPatterned ? -0.15 * 0.10 : 0.0
        let patternCoverage = 1.0

        // Component 4 — structure (weight 0.15). Maps `fitAttribute` to a
        // [-0.10, +0.10] structure score; missing fit drops the component.
        let structureDelta: Double
        let structureCoverage: Double
        let structureSignal: Double // [0, 1]
        if let fit = fitAttribute {
            let s = structureScore(for: fit)
            structureDelta = 0.15 * s
            structureCoverage = 1.0
            structureSignal = (s + 0.10) / 0.20
        } else {
            structureDelta = 0
            structureCoverage = 0
            structureSignal = 0.5
        }

        let value = min(1.0, max(0.0,
            categoryBase + textureDelta + brightnessDelta + patternDelta + structureDelta
        ))
        let coverage = 0.50 * textureCoverage
            + 0.20 * brightnessCoverage
            + 0.15 * patternCoverage
            + 0.15 * structureCoverage

        let components = FormalityComponents(
            colorBrightness: avgLightness,
            textureSmoothness: smoothnessSignal,
            patternScale: isPatterned ? 1.0 : 0.0,
            structuralScore: structureSignal
        )
        return (value, components, coverage)
    }

    /// Per-category baseline formality on the [0, 1] scale.
    static func categoryFormality(_ category: ClothingCategory) -> Double {
        switch category {
        case .top: 0.4
        case .bottom: 0.4
        case .shoe: 0.4
        case .dress: 0.55
        case .outerwear: 0.5
        case .accessory: 0.4
        }
    }

    /// Maps a fit to a structure score in [-0.10, +0.10]: structured
    /// silhouettes read more formal, relaxed/oversized less.
    static func structureScore(for fit: FitAttribute) -> Double {
        switch fit {
        case .structured: 0.10
        case .slim, .regular: 0.05
        case .relaxed: -0.05
        case .oversized: -0.10
        case .cropped: 0.0
        }
    }
}
