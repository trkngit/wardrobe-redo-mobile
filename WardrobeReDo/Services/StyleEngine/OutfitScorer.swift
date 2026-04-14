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

struct DimensionScore: Codable, Sendable {
    let dimension: ScoringDimension
    let value: Double // 0.0 – 1.0
    let reasoning: String
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

struct OutfitScore: Codable, Sendable {
    let totalScore: Double
    let breakdown: [DimensionScore]

    init(breakdown: [DimensionScore]) {
        self.breakdown = breakdown
        self.totalScore = breakdown.reduce(0.0) { sum, score in
            sum + score.value * score.dimension.weight
        }
    }
}
