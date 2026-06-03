import Foundation

// MARK: - Scorer Protocol

/// Each of the 7 scoring dimensions implements this protocol.
/// Returns a 0-1 score plus human-readable reasoning.
protocol OutfitScorer {
    var dimension: ScoringDimension { get }
    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore
}

// MARK: - Scoring Dimensions

enum ScoringDimension: String, CaseIterable, Codable, Sendable {
    case proportionBalance = "proportion_balance"
    case colorHarmony = "color_harmony"
    case textureMix = "texture_mix"
    case formalityCoherence = "formality_coherence"
    case outfitFormula = "outfit_formula"
    case versatility = "versatility"
    case occasionContext = "occasion_context"

    var weight: Double {
        switch self {
        case .proportionBalance: 0.15
        case .colorHarmony: 0.25
        case .textureMix: 0.10
        case .formalityCoherence: 0.15
        case .outfitFormula: 0.15
        case .versatility: 0.10
        case .occasionContext: 0.10
        }
    }

    var displayName: String {
        switch self {
        case .proportionBalance: "Proportion"
        case .colorHarmony: "Color"
        case .textureMix: "Texture"
        case .formalityCoherence: "Formality"
        case .outfitFormula: "Formula"
        case .versatility: "Versatility"
        case .occasionContext: "Context"
        }
    }
}

// MARK: - Dimension Score

/// Per-dimension contribution to an outfit's aggregate score. Build 6
/// added `coverage ∈ [0,1]` so the aggregator can weight-renormalize
/// across dimensions that actually had data instead of diluting the
/// total with `0.5` fallbacks. A `coverage = 0` dimension contributes
/// nothing to either side of the weighted average — its weight is
/// excluded and the remaining weights are renormalized to sum to 1.
///
/// **Backward compatibility.** Persisted JSON written before build 6
/// has no `coverage` key. The decoder defaults missing values to
/// `1.0` because the pre-coverage scoring code always assumed full
/// data was present — that's the value-preserving semantic.
struct DimensionScore: Codable, Sendable {
    let dimension: ScoringDimension
    let value: Double      // 0.0 – 1.0
    let coverage: Double   // 0.0 – 1.0; share of data the dimension had
    let reasoning: String

    init(
        dimension: ScoringDimension,
        value: Double,
        coverage: Double = 1.0,
        reasoning: String
    ) {
        self.dimension = dimension
        self.value = value
        self.coverage = coverage
        self.reasoning = reasoning
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.dimension = try c.decode(ScoringDimension.self, forKey: .dimension)
        self.value = try c.decode(Double.self, forKey: .value)
        self.coverage = try c.decodeIfPresent(Double.self, forKey: .coverage) ?? 1.0
        self.reasoning = try c.decode(String.self, forKey: .reasoning)
    }

    private enum CodingKeys: String, CodingKey {
        case dimension, value, coverage, reasoning
    }
}

// MARK: - Scoring Context

/// Per-request inputs threaded through every scorer. Build 6 added
/// `recentOutfitItemPairs` to power `VersatilityScorer`'s novelty
/// bonus — the field that the docstring promised since the engine
/// shipped but the code never implemented. The set is empty for
/// fresh users (no saved outfits yet) and the scorer treats that
/// as "no novelty signal" → `coverage = 0` on the sub-component.
struct ScoringContext: Sendable {
    let season: Season
    let occasion: Occasion
    let dayOfWeek: String // "monday", "tuesday", etc.
    let wardrobeItemCount: Int
    let recentOutfitItemIds: Set<UUID> // items used in last 7 days
    let recentOutfitItemPairs: Set<UnorderedItemPair> // pairs seen in last 30 outfits
    /// Full item-sets of outfits suggested or worn in the last 14 days
    /// (Build 49, TF49 #6). `VersatilityScorer` hard-penalizes any
    /// candidate whose exact item-set appears here, so the same
    /// combination won't resurface within two weeks. Empty for fresh
    /// users → no cooldown signal, scorer is unaffected.
    let recentOutfitItemSets: Set<Set<UUID>>
    /// Per-generation vibe preset (build 6). Each scorer that's
    /// vibe-aware reads from this — color harmony reads
    /// `colorMaxFamilies`, formula reads `formulaStrictness`,
    /// versatility reads `noveltyRewardMultiplier`. The
    /// `OutfitScore` aggregator reads `weightDeltas` to renormalize
    /// the overall weight vector. Defaults to `.balanced` so legacy
    /// call sites compile unchanged and behave like build-5.
    let vibePreset: VibePreset

    init(
        season: Season,
        occasion: Occasion,
        dayOfWeek: String,
        wardrobeItemCount: Int,
        recentOutfitItemIds: Set<UUID>,
        recentOutfitItemPairs: Set<UnorderedItemPair> = [],
        recentOutfitItemSets: Set<Set<UUID>> = [],
        vibePreset: VibePreset = .balanced
    ) {
        self.season = season
        self.occasion = occasion
        self.dayOfWeek = dayOfWeek
        self.wardrobeItemCount = wardrobeItemCount
        self.recentOutfitItemIds = recentOutfitItemIds
        self.recentOutfitItemPairs = recentOutfitItemPairs
        self.recentOutfitItemSets = recentOutfitItemSets
        self.vibePreset = vibePreset
    }
}

/// Unordered pair of wardrobe item IDs. Used by
/// `VersatilityScorer` to detect novel combinations: an outfit
/// whose item-pair set contains pairs the user hasn't worn
/// together recently scores higher than one that just reshuffles
/// the same handful of pairings.
struct UnorderedItemPair: Hashable, Sendable {
    let lhs: UUID
    let rhs: UUID

    init(_ a: UUID, _ b: UUID) {
        // Canonical ordering: lhs always lexicographically ≤ rhs so
        // `{A,B}` and `{B,A}` hash identically.
        if a.uuidString <= b.uuidString {
            self.lhs = a
            self.rhs = b
        } else {
            self.lhs = b
            self.rhs = a
        }
    }
}

// MARK: - Aggregate Score

/// Aggregate outfit score. Build 6 changed the aggregation from a
/// raw weighted sum to a coverage-aware weighted average:
///
///     totalScore = Σ (value × weight × coverage) / Σ (weight × coverage)
///
/// Dimensions with `coverage = 0` are excluded entirely. Outfits with
/// fewer than `minCoveredDimensions` (4 of 7) populated dimensions
/// are flagged `isLowCoverage` so the UI can surface "Insufficient
/// data" instead of a numeric score.
struct OutfitScore: Codable, Sendable {
    let totalScore: Double
    let breakdown: [DimensionScore]
    let coveredDimensionCount: Int

    /// Threshold below which the outfit is considered to have too
    /// little data to score meaningfully. 4 of 7 ≈ majority of
    /// dimensions contributed real signal.
    static let minCoveredDimensions: Int = 4

    var isLowCoverage: Bool { coveredDimensionCount < Self.minCoveredDimensions }

    init(breakdown: [DimensionScore], vibePreset: VibePreset = .balanced) {
        self.breakdown = breakdown

        // Build 6 composes two renormalizations:
        //   1. Vibe preset adjusts each dimension's base weight via
        //      `VibePreset.renormalizedWeights`. A `.bold` outfit
        //      gives Versatility more weight; `.safe` gives Color
        //      more.
        //   2. Coverage strips zero-coverage dimensions from the
        //      weighted average and renormalizes again. An outfit
        //      with no texture data doesn't pay the texture penalty.
        //
        // The composition order matters: vibe runs first because
        // it expresses user intent (which dimensions matter today);
        // coverage runs second because it filters by data
        // availability (which dimensions we can actually evaluate).
        let baseWeights = Dictionary(
            uniqueKeysWithValues: ScoringDimension.allCases.map { ($0, $0.weight) }
        )
        let vibeWeights = VibePreset.renormalizedWeights(base: baseWeights, preset: vibePreset)

        let covered = breakdown.filter { $0.coverage > 0 }
        let weightedSum = covered.reduce(0.0) { acc, dim in
            let w = vibeWeights[dim.dimension] ?? dim.dimension.weight
            return acc + dim.value * w * dim.coverage
        }
        let weightDenom = covered.reduce(0.0) { acc, dim in
            let w = vibeWeights[dim.dimension] ?? dim.dimension.weight
            return acc + w * dim.coverage
        }
        self.totalScore = weightDenom > 0 ? weightedSum / weightDenom : 0.5
        self.coveredDimensionCount = covered.count
    }

    // Codable: persisted JSON pre-build-6 omits `coveredDimensionCount`.
    // Decode falls back to counting it from the (possibly legacy)
    // breakdown so historical scores still hydrate cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.totalScore = try c.decode(Double.self, forKey: .totalScore)
        self.breakdown = try c.decode([DimensionScore].self, forKey: .breakdown)
        self.coveredDimensionCount = try c.decodeIfPresent(Int.self, forKey: .coveredDimensionCount)
            ?? self.breakdown.filter { $0.coverage > 0 }.count
    }

    private enum CodingKeys: String, CodingKey {
        case totalScore, breakdown, coveredDimensionCount
    }
}
