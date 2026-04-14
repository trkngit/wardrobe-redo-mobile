import Foundation

/// Scores multi-dimensional formality coherence across items.
/// Uses color brightness, texture smoothness, pattern, and structure —
/// not just a single formality number.
struct FormalityCoherenceScorer: OutfitScorer {
    let dimension = ScoringDimension.formalityCoherence

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        guard !items.isEmpty else {
            return DimensionScore(dimension: dimension, value: 0.5, reasoning: "No items to evaluate")
        }

        var totalScore = 0.0
        var reasons: [String] = []

        // 1. Compute effective formality for each item
        let formalities = items.compactMap { effectiveFormality(for: $0) }
        guard formalities.count >= 2 else {
            return DimensionScore(dimension: dimension, value: 0.7, reasoning: "Single item — formality is self-coherent")
        }

        // 2. Formality spread (how close are items to each other?)
        let avgFormality = formalities.reduce(0.0, +) / Double(formalities.count)
        let maxDiff = formalities.map { abs($0 - avgFormality) }.max() ?? 0

        if maxDiff <= 0.1 {
            totalScore += 0.4
            reasons.append("Tight formality coherence — all items match")
        } else if maxDiff <= 0.2 {
            totalScore += 0.3
            reasons.append("Good formality alignment")
        } else if maxDiff <= 0.35 {
            totalScore += 0.2
            reasons.append("Moderate formality tension — intentional contrast?")
        } else {
            totalScore += 0.05
            reasons.append("Formality clash — items from different dress codes")
        }

        // 3. Does average formality fit the archetype's range?
        let fMin = archetype.formalityMin
        let fMax = archetype.formalityMax

        if avgFormality >= fMin && avgFormality <= fMax {
            totalScore += 0.35
            reasons.append("Formality level fits \(archetype.editorialName) archetype")
        } else {
            let distance = avgFormality < fMin
                ? fMin - avgFormality
                : avgFormality - fMax
            let penalty = min(0.3, distance)
            totalScore += max(0.0, 0.35 - penalty)
            reasons.append("Formality level is \(avgFormality < fMin ? "too casual" : "too formal") for this archetype")
        }

        // 4. Occasion appropriateness
        let occasionFormality = occasionFormalityRange(context.occasion)
        if avgFormality >= occasionFormality.min && avgFormality <= occasionFormality.max {
            totalScore += 0.25
            reasons.append("Appropriate formality for \(context.occasion.displayName)")
        } else {
            totalScore += 0.08
            let direction = avgFormality < occasionFormality.min ? "underdressed" : "overdressed"
            reasons.append("Slightly \(direction) for \(context.occasion.displayName)")
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            reasoning: reasons.joined(separator: ". ")
        )
    }

    // MARK: - Effective Formality

    /// Computes formality from components if available, else estimates from texture/category.
    private func effectiveFormality(for item: WardrobeItem) -> Double? {
        if let computed = item.formalityComputed {
            return computed
        }

        // Estimate from category and texture
        var base: Double = categoryFormality(item.category)

        if let texture = item.texture {
            // Smoothness 0-10, map to formality adjustment
            let smoothnessBoost = (texture.formalitySmoothness - 5.0) * 0.03
            base += smoothnessBoost
        }

        return min(1.0, max(0.0, base))
    }

    private func categoryFormality(_ category: ClothingCategory) -> Double {
        switch category {
        case .top: 0.4
        case .bottom: 0.4
        case .shoe: 0.4
        case .dress: 0.55
        case .outerwear: 0.5
        case .accessory: 0.4
        }
    }

    private func occasionFormalityRange(_ occasion: Occasion) -> (min: Double, max: Double) {
        switch occasion {
        case .casual: (0.05, 0.45)
        case .work: (0.35, 0.75)
        case .date: (0.3, 0.7)
        case .formal: (0.65, 1.0)
        case .athletic: (0.0, 0.3)
        case .lounge: (0.0, 0.2)
        }
    }
}
