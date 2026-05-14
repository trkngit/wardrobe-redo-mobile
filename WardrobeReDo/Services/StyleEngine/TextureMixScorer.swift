import Foundation

/// Scores texture mixing: 2-3 textures optimal, visual weight balance,
/// heavy+light pairing, context appropriateness.
struct TextureMixScorer: OutfitScorer {
    let dimension = ScoringDimension.textureMix

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        let textures = items.compactMap(\.texture)
        guard !textures.isEmpty else {
            return DimensionScore(
                dimension: dimension,
                value: 0.5,
                coverage: 0.0,
                reasoning: "No texture data available"
            )
        }

        var totalScore = 0.0
        var reasons: [String] = []
        let uniqueTextures = Set(textures)
        let textureCount = uniqueTextures.count

        // 1. Texture count (2-3 is optimal)
        switch textureCount {
        case 1:
            totalScore += 0.2
            reasons.append("Single texture — consistent but lacks depth")
        case 2:
            totalScore += 0.35
            reasons.append("Two textures create nice contrast")
        case 3:
            totalScore += 0.35
            reasons.append("Three textures — rich tactile variety")
        case 4:
            totalScore += 0.2
            reasons.append("Four textures — slightly busy")
        default:
            totalScore += 0.1
            reasons.append("Too many textures compete")
        }

        // 2. Visual weight balance (heavy + light = good contrast)
        let weights = textures.map(\.visualWeight)
        let hasLight = weights.contains(.light)
        let hasHeavy = weights.contains(.heavy)
        let hasMedium = weights.contains(.medium)

        if hasLight && hasHeavy {
            totalScore += 0.25
            reasons.append("Good heavy-light texture contrast")
        } else if (hasLight && hasMedium) || (hasMedium && hasHeavy) {
            totalScore += 0.2
            reasons.append("Moderate visual weight variation")
        } else if weights.allSatisfy({ $0 == weights.first }) {
            totalScore += 0.1
            reasons.append("Uniform visual weight — no texture contrast")
        } else {
            totalScore += 0.15
        }

        // 3. Formality smoothness coherence
        let smoothness = textures.map(\.formalitySmoothness)
        if let maxSmooth = smoothness.max(), let minSmooth = smoothness.min() {
            let range = maxSmooth - minSmooth
            if range <= 3.0 {
                totalScore += 0.2
                reasons.append("Texture formality levels are cohesive")
            } else if range <= 5.0 {
                totalScore += 0.1
                reasons.append("Some texture formality tension")
            } else {
                totalScore += 0.03
                reasons.append("Silk + denim-level texture clash")
            }
        }

        // 4. Check against rule's texture constraints
        if let textureRule = rule.textureRule {
            if let minTex = textureRule.minTextures, textureCount < minTex {
                totalScore = max(0.0, totalScore - 0.1)
                reasons.append("Below minimum texture count (\(minTex))")
            }
            if let maxTex = textureRule.maxTextures, textureCount > maxTex {
                totalScore = max(0.0, totalScore - 0.1)
                reasons.append("Exceeds maximum texture count (\(maxTex))")
            }
            if textureRule.requiredContrast == true && !hasLight && !hasHeavy {
                totalScore = max(0.0, totalScore - 0.1)
                reasons.append("Rule requires texture contrast")
            }
        }

        // 5. Check archetype texture preferences
        if let texPrefs = archetype.texturePreferences {
            let preferredSet = Set(texPrefs.preferred ?? [])
            let avoidedSet = Set(texPrefs.avoided ?? [])
            let usedSet = Set(textures.map(\.rawValue))

            let matchCount = usedSet.intersection(preferredSet).count
            let avoidCount = usedSet.intersection(avoidedSet).count

            if matchCount > 0 && avoidCount == 0 {
                totalScore = min(1.0, totalScore + 0.15)
                reasons.append("Uses preferred textures for this archetype")
            } else if avoidCount > 0 {
                totalScore = max(0.0, totalScore - 0.1)
                reasons.append("Contains textures avoided by this archetype")
            }
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            reasoning: reasons.joined(separator: ". ")
        )
    }
}
