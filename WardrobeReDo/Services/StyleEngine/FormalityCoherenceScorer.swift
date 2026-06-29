import Foundation

/// Scores multi-dimensional formality coherence across items.
/// Uses color brightness, texture smoothness, pattern, and structure —
/// not just a single formality number.
struct FormalityCoherenceScorer: OutfitScorer {
    let dimension = ScoringDimension.formalityCoherence

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        guard !items.isEmpty else {
            return DimensionScore(
                dimension: dimension,
                value: 0.5,
                coverage: 0.0,
                reasoning: "No items to evaluate"
            )
        }

        var totalScore = 0.0
        var reasons: [String] = []

        // 1. Compute effective formality for each item. Each item
        // returns both a value and a coverage fraction tracking how
        // many of the four declared inputs actually fired. We
        // average the per-item coverage to get the dimension-level
        // coverage so an outfit of well-tagged items scores with
        // higher confidence than one assembled from minimal-data
        // items.
        let perItem = items.compactMap { effectiveFormality(for: $0) }
        let formalities = perItem.map(\.value)
        let perItemCoverage = perItem.map(\.coverage)
        let dimensionCoverage = perItemCoverage.isEmpty
            ? 0.0
            : perItemCoverage.reduce(0.0, +) / Double(perItemCoverage.count)
        guard formalities.count >= 2 else {
            return DimensionScore(
                dimension: dimension,
                value: 0.7,
                coverage: dimensionCoverage,
                reasoning: "Single item — formality is self-coherent"
            )
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
            coverage: dimensionCoverage,
            reasoning: reasons.joined(separator: ". ")
        )
    }

    // MARK: - Effective Formality
    //
    // The full multi-input formula (texture smoothness, color
    // brightness, pattern, structure) lives in `FormalityFormula` so
    // it is the single source of truth shared with the add flow, which
    // computes + persists `formalityComputed` at save time (TF52). This
    // scorer only decides whether to trust a persisted value or fall
    // back to recomputing.

    /// Computes effective formality + a coverage fraction in [0,1]
    /// for a single item. Returns nil only when the item itself
    /// lacks a category (which can't happen in practice — category
    /// is NOT NULL — but the optional return keeps the call site
    /// honest).
    fileprivate func effectiveFormality(for item: WardrobeItem) -> (value: Double, coverage: Double)? {
        // A precomputed formality means the add flow already ran the
        // full `FormalityFormula` computation and persisted the result
        // — trust it at full coverage.
        if let computed = item.formalityComputed {
            return (computed, 1.0)
        }

        let result = FormalityFormula.compute(
            category: item.category,
            texture: item.texture,
            dominantColors: item.dominantColors,
            fitAttribute: item.fitAttribute
        )
        return (result.value, result.coverage)
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
