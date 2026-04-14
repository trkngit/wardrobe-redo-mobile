import Foundation

/// Scores outfit versatility: item frequency penalty, novel combination bonus,
/// least-worn item bonus. Encourages using the full wardrobe.
struct VersatilityScorer: OutfitScorer {
    let dimension = ScoringDimension.versatility

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        guard !items.isEmpty else {
            return DimensionScore(dimension: dimension, value: 0.5, reasoning: "No items to evaluate")
        }

        var totalScore = 0.0
        var reasons: [String] = []

        // 1. Item frequency (prefer less-worn items)
        let wearCounts = items.map(\.wearCount)
        let avgWearCount = Double(wearCounts.reduce(0, +)) / Double(wearCounts.count)

        if avgWearCount <= 2 {
            totalScore += 0.35
            reasons.append("Fresh items — rarely worn combination")
        } else if avgWearCount <= 5 {
            totalScore += 0.25
            reasons.append("Moderate wear counts — good rotation")
        } else if avgWearCount <= 10 {
            totalScore += 0.15
            reasons.append("Well-worn items — consider mixing things up")
        } else {
            totalScore += 0.05
            reasons.append("Heavily-worn items — wardrobe staples but lacks variety")
        }

        // 2. Recent usage penalty (don't repeat items from last 7 days)
        let recentIds = context.recentOutfitItemIds
        let recentlyUsed = items.filter { recentIds.contains($0.id) }
        let recentRatio = Double(recentlyUsed.count) / Double(items.count)

        if recentlyUsed.isEmpty {
            totalScore += 0.3
            reasons.append("All fresh — no recent repeats")
        } else if recentRatio <= 0.33 {
            totalScore += 0.2
            reasons.append("Mostly fresh with one recent repeat")
        } else if recentRatio <= 0.5 {
            totalScore += 0.1
            reasons.append("Half the items were worn recently")
        } else {
            totalScore += 0.02
            reasons.append("Most items worn in the last week")
        }

        // 3. Least-worn item bonus (include at least one underused piece)
        let minWearCount = wearCounts.min() ?? 0
        if minWearCount == 0 {
            totalScore += 0.2
            reasons.append("Includes a never-worn item — great for variety")
        } else if minWearCount <= 2 {
            totalScore += 0.15
            reasons.append("Includes a rarely-worn piece")
        } else {
            totalScore += 0.05
        }

        // 4. Wardrobe coverage bonus (outfit uses items from different categories)
        let categories = Set(items.map(\.category))
        if categories.count >= 3 {
            totalScore += 0.15
            reasons.append("Multi-category outfit — good wardrobe utilization")
        } else if categories.count >= 2 {
            totalScore += 0.1
            reasons.append("Standard category mix")
        } else {
            totalScore += 0.03
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            reasoning: reasons.joined(separator: ". ")
        )
    }
}
