import Foundation

/// Scores silhouette pairing: oversized+slim = good, oversized+oversized = risky.
/// Evaluates top/bottom fit balance per the archetype's proportion preferences.
struct ProportionBalanceScorer: OutfitScorer {
    let dimension = ScoringDimension.proportionBalance

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        let tops = items.filter { $0.category == .top || $0.category == .outerwear }
        let bottoms = items.filter { $0.category == .bottom }

        // Dresses are self-contained — automatic good proportion
        if items.contains(where: { $0.category == .dress }) {
            return DimensionScore(dimension: dimension, value: 0.85, reasoning: "Dress provides balanced silhouette")
        }

        guard let topFit = tops.compactMap(\.fitAttribute).first,
              let bottomFit = bottoms.compactMap(\.fitAttribute).first else {
            return DimensionScore(
                dimension: dimension,
                value: 0.5,
                coverage: 0.0,
                reasoning: "Missing fit data for proportion scoring"
            )
        }

        var score = 0.0
        var reasons: [String] = []

        // Core balance scoring
        let pair = (topFit, bottomFit)
        switch pair {
        case (.oversized, .slim), (.relaxed, .slim):
            score += 0.9
            reasons.append("Volume on top + slim below creates visual balance")
        case (.slim, .slim), (.regular, .slim):
            score += 0.8
            reasons.append("Clean streamlined silhouette")
        case (.structured, .slim):
            score += 0.85
            reasons.append("Structured top with slim bottom is sharp")
        case (.regular, .regular):
            score += 0.7
            reasons.append("Balanced regular proportions")
        case (.oversized, .regular):
            score += 0.65
            reasons.append("Oversized top with regular bottom works")
        case (.relaxed, .relaxed):
            score += 0.5
            reasons.append("Double relaxed can lack definition")
        case (.oversized, .oversized), (.oversized, .relaxed):
            score += 0.3
            reasons.append("Double volume risks losing shape")
        case (.cropped, .slim), (.cropped, .regular):
            score += 0.8
            reasons.append("Cropped top balances well with defined bottom")
        default:
            score += 0.6
            reasons.append("Acceptable proportion pairing")
        }

        // Check against archetype preferences
        if let propPrefs = archetype.proportionPreferences {
            let topStr = topFit.rawValue
            let bottomStr = bottomFit.rawValue

            if let allowed = propPrefs.preferredBalances {
                let isPreferred = allowed.contains { $0 == [topStr, bottomStr] }
                if isPreferred {
                    score = min(1.0, score + 0.1)
                    reasons.append("Matches archetype's preferred proportions")
                }
            }

            if propPrefs.allowOversized == false && (topFit == .oversized || bottomFit == .oversized) {
                score = max(0.0, score - 0.2)
                reasons.append("Archetype prefers no oversized pieces")
            }
        }

        // Check rule's proportion constraints
        if let propRule = rule.proportionRule {
            if let forbidden = propRule.forbidden {
                let isForbidden = forbidden.contains { $0 == [topFit.rawValue, bottomFit.rawValue] }
                if isForbidden {
                    score = max(0.0, score - 0.3)
                    reasons.append("Proportion pairing is forbidden by this rule")
                }
            }
        }

        return DimensionScore(dimension: dimension, value: min(1.0, max(0.0, score)), reasoning: reasons.joined(separator: ". "))
    }
}
