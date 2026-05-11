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

    // MARK: - Effective Formality (build 6 — 4 inputs)
    //
    // ENGINE.md has always claimed formality is derived from
    // "color brightness, texture smoothness, pattern, and
    // structure." Before build 6, the implementation used texture
    // smoothness only. The 4-input formula below restores the
    // documented behaviour using proxies we can compute from
    // existing fields:
    //
    //   • Texture smoothness (weight 0.50). Existing.
    //   • Color brightness (weight 0.20). Mean lightness of
    //     `dominantColors`; darker → more formal. Inverse so high
    //     lightness *reduces* the delta.
    //   • Pattern proxy (weight 0.15). If the item has ≥3 distinct
    //     dominant colors we treat it as patterned/multicolor,
    //     which reduces formality by a small constant.
    //   • Structure (weight 0.15). Derived from `fitAttribute`:
    //     structured > slim/regular > relaxed > oversized.
    //
    // Per-item coverage is reported back to the dimension as the
    // share of components that actually contributed — so a fully-
    // tagged item gives coverage = 1.0, a category-only item
    // (no texture, no fit, no colors) gives coverage = 0.15
    // (pattern proxy is always inferable from `dominantColors.count`,
    // even if the array is empty).

    /// Computes effective formality + a coverage fraction in [0,1]
    /// for a single item. Returns nil only when the item itself
    /// lacks a category (which can't happen in practice — category
    /// is NOT NULL — but the optional return keeps the call site
    /// honest).
    fileprivate func effectiveFormality(for item: WardrobeItem) -> (value: Double, coverage: Double)? {
        // If we have a precomputed formality, trust it — coverage
        // = 1.0 because some upstream layer did the full
        // multi-input computation.
        if let computed = item.formalityComputed {
            return (computed, 1.0)
        }

        let categoryBase = categoryFormality(item.category)

        // Component 1 — texture smoothness (weight 0.50).
        let textureDelta: Double
        let textureCov: Double
        if let texture = item.texture {
            textureDelta = 0.50 * (Double(texture.formalitySmoothness) - 5.0) * 0.03
            textureCov = 1.0
        } else {
            textureDelta = 0
            textureCov = 0
        }

        // Component 2 — color brightness (weight 0.20). Average
        // lightness across the dominant-color palette; darker
        // reads more formal.
        let brightnessDelta: Double
        let brightnessCov: Double
        if !item.dominantColors.isEmpty {
            let avgLightness = item.dominantColors
                .map(\.lightness)
                .reduce(0.0, +) / Double(item.dominantColors.count)
            // Lightness in [0,1]. Centered at 0.5; values closer to
            // 0 push formality up by up to 0.20 × 0.5 × 0.4 = 0.04.
            brightnessDelta = 0.20 * (0.5 - avgLightness) * 0.4
            brightnessCov = 1.0
        } else {
            brightnessDelta = 0
            brightnessCov = 0
        }

        // Component 3 — pattern proxy (weight 0.15). ≥3 dominant
        // color clusters → likely patterned → reduce formality
        // slightly. Always covered: `dominantColors.count` is
        // always defined (the array may be empty, which we treat
        // as "solid color, no pattern").
        let isPatterned = item.dominantColors.count >= 3
        let patternDelta = isPatterned ? -0.15 * 0.10 : 0.0
        let patternCov = 1.0

        // Component 4 — structure (weight 0.15). Map fitAttribute
        // to a [-0.10, +0.10] structure score; missing fit drops
        // the component from coverage.
        let structureDelta: Double
        let structureCov: Double
        if let fit = item.fitAttribute {
            let s = structureScore(for: fit)
            structureDelta = 0.15 * s
            structureCov = 1.0
        } else {
            structureDelta = 0
            structureCov = 0
        }

        let value = min(1.0, max(0.0,
            categoryBase + textureDelta + brightnessDelta + patternDelta + structureDelta
        ))
        let coverage = 0.50 * textureCov
            + 0.20 * brightnessCov
            + 0.15 * patternCov
            + 0.15 * structureCov
        return (value, coverage)
    }

    private func structureScore(for fit: FitAttribute) -> Double {
        switch fit {
        case .structured: 0.10
        case .slim, .regular: 0.05
        case .relaxed: -0.05
        case .oversized: -0.10
        case .cropped: 0.0
        }
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
