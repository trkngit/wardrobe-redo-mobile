import Foundation

/// Scores how well the outfit matches the target season, occasion,
/// and day-of-week context. Applies archetype boost/penalty conditions.
struct OccasionContextScorer: OutfitScorer {
    let dimension = ScoringDimension.occasionContext

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        guard !items.isEmpty else {
            return DimensionScore(dimension: dimension, value: 0.5, reasoning: "No items to evaluate")
        }

        var totalScore = 0.0
        var reasons: [String] = []

        // 1. Season match — do the items' seasons include the current season?
        let seasonScore = scoreSeasonMatch(items: items, season: context.season)
        totalScore += seasonScore.value
        reasons.append(seasonScore.reason)

        // 2. Occasion match — do the items' occasions include the target?
        let occasionScore = scoreOccasionMatch(items: items, occasion: context.occasion)
        totalScore += occasionScore.value
        reasons.append(occasionScore.reason)

        // 3. Archetype season/occasion fit
        let archetypeScore = scoreArchetypeFit(archetype: archetype, context: context)
        totalScore += archetypeScore.value
        reasons.append(archetypeScore.reason)

        // 4. Boost/penalty conditions from rule
        let conditionScore = applyConditions(rule: rule, context: context)
        totalScore += conditionScore.value
        if !conditionScore.reason.isEmpty {
            reasons.append(conditionScore.reason)
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            reasoning: reasons.joined(separator: ". ")
        )
    }

    // MARK: - Season Match

    private func scoreSeasonMatch(items: [WardrobeItem], season: Season) -> (value: Double, reason: String) {
        let matchCount = items.filter { $0.seasons.contains(season) }.count
        let ratio = Double(matchCount) / Double(items.count)

        if ratio >= 1.0 {
            return (0.3, "All items are seasonally appropriate")
        } else if ratio >= 0.7 {
            return (0.2, "Most items fit the season")
        } else if ratio >= 0.5 {
            return (0.1, "Some items are out of season")
        } else {
            return (0.03, "Most items are wrong for this season")
        }
    }

    // MARK: - Occasion Match

    private func scoreOccasionMatch(items: [WardrobeItem], occasion: Occasion) -> (value: Double, reason: String) {
        let matchCount = items.filter { $0.occasions.contains(occasion) }.count
        let ratio = Double(matchCount) / Double(items.count)

        if ratio >= 1.0 {
            return (0.3, "All items suit the \(occasion.displayName) context")
        } else if ratio >= 0.7 {
            return (0.2, "Most items work for \(occasion.displayName)")
        } else if ratio >= 0.5 {
            return (0.1, "Mixed occasion fit")
        } else {
            return (0.03, "Items don't match the target occasion")
        }
    }

    // MARK: - Archetype Fit

    private func scoreArchetypeFit(archetype: StyleArchetype, context: ScoringContext) -> (value: Double, reason: String) {
        let seasonMatch = archetype.seasons.contains(context.season.rawValue)
        let occasionMatch = archetype.occasions.contains(context.occasion.rawValue)

        if seasonMatch && occasionMatch {
            return (0.25, "\(archetype.editorialName) is perfect for this context")
        } else if seasonMatch || occasionMatch {
            return (0.12, "\(archetype.editorialName) partially fits this context")
        } else {
            return (0.03, "\(archetype.editorialName) is unconventional for this context")
        }
    }

    // MARK: - Boost/Penalty Conditions

    private func applyConditions(rule: StyleRule, context: ScoringContext) -> (value: Double, reason: String) {
        var bonus = 0.0
        var reasons: [String] = []

        // Seasonal boosts
        if let seasonalBoosts = rule.boostConditions?.seasonalBoosts {
            if let boost = seasonalBoosts[context.season.rawValue], boost > 0 {
                bonus += boost
                reasons.append("+\(Int(boost * 100))% seasonal boost")
            }
        }

        // Day-of-week boosts
        if let dayBoosts = rule.boostConditions?.dayOfWeekBoosts {
            if let boost = dayBoosts[context.dayOfWeek], boost > 0 {
                bonus += boost
                reasons.append("+\(Int(boost * 100))% day-of-week boost")
            }
        }

        // Season penalties
        if let avoidSeasons = rule.penaltyConditions?.avoidSeasons {
            if avoidSeasons.contains(context.season.rawValue) {
                bonus -= 0.15
                reasons.append("Season penalty — avoid in \(context.season.displayName)")
            }
        }

        // Occasion penalties
        if let avoidOccasions = rule.penaltyConditions?.avoidOccasions {
            if avoidOccasions.contains(context.occasion.rawValue) {
                bonus -= 0.15
                reasons.append("Occasion penalty — avoid for \(context.occasion.displayName)")
            }
        }

        return (bonus, reasons.joined(separator: ". "))
    }
}
