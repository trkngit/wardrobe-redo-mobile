import Foundation

// MARK: - VibeStop

/// 5-stop slider that lets the user tell the outfit engine how
/// "safely" they want to dress today. Build 6's user-facing
/// answer to "I want fun outfits, not just polished ones."
///
/// The slider modulates *scoring strictness*, not aesthetic palette —
/// aesthetic is already encoded in the 50 style archetypes. Picking
/// `.bold` doesn't change the archetype the engine selects; it
/// changes how the dimension weights and per-scorer tolerance bands
/// add up when ranking candidates within that archetype.
enum VibeStop: String, Codable, CaseIterable, Sendable, Identifiable {
    case safe
    case polished
    case balanced
    case adventurous
    case bold

    var id: String { rawValue }

    /// 0.0 – 1.0 slider position. Useful for hosting controls that
    /// drive a continuous control + snap to the nearest stop.
    var sliderValue: Double {
        switch self {
        case .safe: 0.0
        case .polished: 0.25
        case .balanced: 0.5
        case .adventurous: 0.75
        case .bold: 1.0
        }
    }

    /// User-facing label.
    var displayName: String {
        switch self {
        case .safe: "Safe"
        case .polished: "Polished"
        case .balanced: "Balanced"
        case .adventurous: "Adventurous"
        case .bold: "Bold"
        }
    }

    /// Build 14 — localized slider label. Same shape as
    /// `Occasion.localizedName`; catalog keys equal the English
    /// `displayName` so the source language stays canonical.
    var localizedName: LocalizedStringResource {
        switch self {
        case .safe:        LocalizedStringResource("Safe")
        case .polished:    LocalizedStringResource("Polished")
        case .balanced:    LocalizedStringResource("Balanced")
        case .adventurous: LocalizedStringResource("Adventurous")
        case .bold:        LocalizedStringResource("Bold")
        }
    }

    /// Short tagline shown under the slider.
    var tagline: String {
        switch self {
        case .safe: "Play it safe"
        case .polished: "Polished classics"
        case .balanced: "A balanced look"
        case .adventurous: "Adventurous mix"
        case .bold: "Break the rules"
        }
    }

    /// Build 14 — localized variant of `tagline` for SwiftUI.
    var localizedTagline: LocalizedStringResource {
        switch self {
        case .safe:        LocalizedStringResource("Play it safe")
        case .polished:    LocalizedStringResource("Polished classics")
        case .balanced:    LocalizedStringResource("A balanced look")
        case .adventurous: LocalizedStringResource("Adventurous mix")
        case .bold:        LocalizedStringResource("Break the rules")
        }
    }

    /// Long-form description for tooltips, Settings, onboarding.
    var description: String {
        switch self {
        case .safe:
            "Maximum convention. Two color families, classic silhouettes, hero piece + third piece required."
        case .polished:
            "Classic adherence. Up to three color families with analogous or complementary harmonies."
        case .balanced:
            "Today's defaults. Three colors, standard silhouettes, two textures."
        case .adventurous:
            "Loose convention. Up to four color families, wider silhouette pairs, three textures rewarded."
        case .bold:
            "Break the rules. Up to five color families, any non-clashing silhouette, novelty rewarded."
        }
    }

    /// Default vibe used at install time + when a user profile row
    /// lacks the column (legacy Supabase rows).
    static let `default`: VibeStop = .balanced
}

// MARK: - VibePreset

/// Per-stop tolerance bands + weight overrides threaded through
/// `ScoringContext.vibePreset`. Each scorer that's vibe-aware reads
/// the relevant field and adjusts its math accordingly.
///
/// All deltas are conservative: a `.bold` outfit doesn't suddenly
/// look like fast fashion, it just gets to relax color-harmony and
/// proportion strictness while picking up extra texture variety and
/// novelty reward.
struct VibePreset: Sendable, Equatable, Codable {
    let stop: VibeStop

    /// Additive deltas applied to each scoring dimension's base
    /// weight. After applying, the weight vector is renormalized so
    /// it still sums to 1.0 — see `renormalizedWeights(base:preset:)`.
    /// Missing dimensions get a `0` delta.
    let weightDeltas: [ScoringDimension: Double]

    /// Maximum number of distinct color families the outfit may
    /// contain before ColorHarmonyScorer flags it as overloaded.
    /// 2 (safe) → 5 (bold).
    let colorMaxFamilies: Int

    /// Multiplier applied to OutfitFormulaScorer's value. 1.0 keeps
    /// formula strictness as-is; values < 1.0 relax formula
    /// adherence for higher-strictness stops.
    let formulaStrictness: Double

    /// Multiplier applied to VersatilityScorer's novelty
    /// sub-component (1.0 baseline, up to 1.5 for `.bold`).
    let noveltyRewardMultiplier: Double

    static func preset(for stop: VibeStop) -> VibePreset {
        switch stop {
        // Strictness + novelty multipliers are intentionally
        // conservative (~13% spread on formula, ~3× spread on
        // novelty). Larger swings flipped the ranking on edge-case
        // outfits that should still respect the user's other axes
        // (color, proportion). Tune via telemetry once we have
        // engagement data.
        case .safe:
            return VibePreset(
                stop: .safe,
                weightDeltas: [
                    .colorHarmony: +0.05,
                    .formalityCoherence: +0.03,
                    .outfitFormula: +0.05,
                    .versatility: -0.05,
                    .textureMix: -0.03,
                ],
                colorMaxFamilies: 2,
                formulaStrictness: 1.05,
                noveltyRewardMultiplier: 0.5
            )
        case .polished:
            return VibePreset(
                stop: .polished,
                weightDeltas: [
                    .colorHarmony: +0.03,
                    .outfitFormula: +0.03,
                    .versatility: -0.02,
                ],
                colorMaxFamilies: 3,
                formulaStrictness: 1.02,
                noveltyRewardMultiplier: 0.8
            )
        case .balanced:
            return VibePreset(
                stop: .balanced,
                weightDeltas: [:],
                colorMaxFamilies: 3,
                formulaStrictness: 1.0,
                noveltyRewardMultiplier: 1.0
            )
        case .adventurous:
            return VibePreset(
                stop: .adventurous,
                weightDeltas: [
                    .colorHarmony: -0.03,
                    .textureMix: +0.03,
                    .versatility: +0.05,
                    .outfitFormula: -0.03,
                ],
                colorMaxFamilies: 4,
                formulaStrictness: 0.97,
                noveltyRewardMultiplier: 1.2
            )
        case .bold:
            return VibePreset(
                stop: .bold,
                weightDeltas: [
                    .colorHarmony: -0.05,
                    .textureMix: +0.05,
                    .versatility: +0.08,
                    .outfitFormula: -0.05,
                    .proportionBalance: -0.03,
                ],
                colorMaxFamilies: 5,
                formulaStrictness: 0.92,
                noveltyRewardMultiplier: 1.5
            )
        }
    }

    static let balanced: VibePreset = preset(for: .balanced)

    /// Apply the preset's weight deltas to the base dimension
    /// weights and renormalize so the resulting weight vector sums
    /// to 1.0. Used by `OutfitScore.init` to compose vibe shifts
    /// with the coverage-aware aggregation from Phase 3.
    static func renormalizedWeights(
        base: [ScoringDimension: Double],
        preset: VibePreset
    ) -> [ScoringDimension: Double] {
        var combined: [ScoringDimension: Double] = [:]
        for dim in ScoringDimension.allCases {
            let baseWeight = base[dim] ?? dim.weight
            let delta = preset.weightDeltas[dim] ?? 0
            combined[dim] = max(0, baseWeight + delta)
        }
        let total = combined.values.reduce(0, +)
        guard total > 0 else { return base }
        for dim in combined.keys {
            combined[dim] = (combined[dim] ?? 0) / total
        }
        return combined
    }
}
