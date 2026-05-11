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

struct ScoringContext: Sendable {
    let season: Season
    let occasion: Occasion
    let dayOfWeek: String // "monday", "tuesday", etc.
    let wardrobeItemCount: Int
    let recentOutfitItemIds: Set<UUID> // items used in last 7 days
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

    init(breakdown: [DimensionScore]) {
        self.breakdown = breakdown
        let covered = breakdown.filter { $0.coverage > 0 }
        let weightedSum = covered.reduce(0.0) { acc, dim in
            acc + dim.value * dim.dimension.weight * dim.coverage
        }
        let weightDenom = covered.reduce(0.0) { acc, dim in
            acc + dim.dimension.weight * dim.coverage
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
