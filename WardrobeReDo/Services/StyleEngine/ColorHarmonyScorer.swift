import Foundation

/// Scores color harmony: 3-color max, 60-30-10 allocation, value contrast,
/// saturation coherence, and harmony type classification.
struct ColorHarmonyScorer: OutfitScorer {
    let dimension = ScoringDimension.colorHarmony

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        let allColors = items.flatMap(\.dominantColors)
        guard !allColors.isEmpty else {
            return DimensionScore(dimension: dimension, value: 0.5, reasoning: "No color data available")
        }

        var totalScore = 0.0
        var reasons: [String] = []

        // 1. Color count (3-color max principle)
        let uniqueFamilies = Set(allColors.map(\.colorFamily))
        let familyCount = uniqueFamilies.count

        switch familyCount {
        case 1:
            totalScore += 0.25
            reasons.append("Monochromatic palette")
        case 2:
            totalScore += 0.25
            reasons.append("Clean two-color palette")
        case 3:
            totalScore += 0.25
            reasons.append("Ideal three-color palette")
        case 4:
            totalScore += 0.15
            reasons.append("Four colors — slightly busy")
        default:
            totalScore += 0.05
            reasons.append("Too many colors compete for attention")
        }

        // 2. 60-30-10 allocation check
        let colorsByFamily = Dictionary(grouping: allColors, by: \.colorFamily)
        let percentages = colorsByFamily.mapValues { colors in
            colors.reduce(0.0) { $0 + $1.percentage } / Double(items.count)
        }
        .values
        .sorted(by: >)

        if percentages.count >= 2 {
            let dominant = percentages[0]
            if dominant >= 45 && dominant <= 75 {
                totalScore += 0.2
                reasons.append("Good dominant color proportion (\(Int(dominant))%)")
            } else if dominant >= 35 {
                totalScore += 0.1
                reasons.append("Acceptable color distribution")
            } else {
                totalScore += 0.05
                reasons.append("No clear dominant color")
            }
        } else {
            totalScore += 0.15
        }

        // 3. Value contrast (lightness difference)
        let lightnesses = allColors.map(\.lightness)
        if let maxL = lightnesses.max(), let minL = lightnesses.min() {
            let contrast = maxL - minL
            if contrast >= 0.3 && contrast <= 0.7 {
                totalScore += 0.2
                reasons.append("Good light-dark contrast")
            } else if contrast >= 0.15 {
                totalScore += 0.12
                reasons.append("Moderate value contrast")
            } else {
                totalScore += 0.05
                reasons.append("Low value contrast — may look flat")
            }
        }

        // 4. Saturation coherence
        let saturations = allColors.map(\.saturation)
        if let maxS = saturations.max(), let minS = saturations.min() {
            let satRange = maxS - minS
            if satRange <= 0.3 {
                totalScore += 0.15
                reasons.append("Cohesive saturation levels")
            } else if satRange <= 0.5 {
                totalScore += 0.1
                reasons.append("Moderate saturation variation")
            } else {
                totalScore += 0.03
                reasons.append("Saturation clash — muted vs vivid")
            }
        }

        // 5. Harmony type classification
        let hues = allColors.filter { !$0.isNeutral }.map(\.hue)
        let harmonyType = classifyHarmony(hues: hues)
        let preferredHarmony = rule.preferredHarmony

        if harmonyType == preferredHarmony || harmonyType == "neutral" {
            totalScore += 0.2
            reasons.append("Color harmony matches archetype (\(harmonyType))")
        } else if harmonyType == "monochromatic" || harmonyType == "analogous" {
            totalScore += 0.12
            reasons.append("\(harmonyType.capitalized) harmony — safe choice")
        } else {
            totalScore += 0.05
            reasons.append("\(harmonyType.capitalized) harmony — doesn't match preferred \(preferredHarmony)")
        }

        // Neutral bias bonus
        if let colorPrefs = archetype.colorPreferences {
            let neutralCount = allColors.filter(\.isNeutral).count
            let neutralRatio = Double(neutralCount) / Double(allColors.count)
            let bias = colorPrefs.neutralBias ?? 0.5

            if abs(neutralRatio - bias) <= 0.2 {
                totalScore = min(1.0, totalScore + 0.05)
                reasons.append("Neutral balance matches archetype preference")
            }
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            reasoning: reasons.joined(separator: ". ")
        )
    }

    // MARK: - Harmony Classification

    private func classifyHarmony(hues: [Double]) -> String {
        guard !hues.isEmpty else { return "neutral" }
        guard hues.count >= 2 else { return "monochromatic" }

        let sorted = hues.sorted()
        let distances = zip(sorted, sorted.dropFirst()).map { abs($1 - $0) }

        // All hues within 30° — monochromatic
        if let maxDist = distances.max(), maxDist <= 30 {
            return "monochromatic"
        }

        // All hues within 60° — analogous
        if let maxDist = distances.max(), maxDist <= 60 {
            return "analogous"
        }

        // Check for complementary (hues ~180° apart)
        for i in 0..<hues.count {
            for j in (i + 1)..<hues.count {
                let diff = abs(hues[i] - hues[j])
                let hueDist = min(diff, 360 - diff)
                if hueDist >= 150 && hueDist <= 210 {
                    return "complementary"
                }
            }
        }

        // Check for triadic (hues ~120° apart)
        if hues.count >= 3 {
            let diffs = [
                hueDistance(hues[0], hues[1]),
                hueDistance(hues[1], hues[2]),
                hueDistance(hues[0], hues[2]),
            ]
            if diffs.allSatisfy({ $0 >= 90 && $0 <= 150 }) {
                return "triadic"
            }
        }

        return "mixed"
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b)
        return min(diff, 360 - diff)
    }
}
