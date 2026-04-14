import Foundation

/// Scores outfit formula adherence: hero piece method, 2-of-3 color matching,
/// third piece rule, slot requirement satisfaction.
struct OutfitFormulaScorer: OutfitScorer {
    let dimension = ScoringDimension.outfitFormula

    func score(items: [WardrobeItem], archetype: StyleArchetype, rule: StyleRule, context: ScoringContext) -> DimensionScore {
        guard !items.isEmpty else {
            return DimensionScore(dimension: dimension, value: 0.0, reasoning: "No items")
        }

        var totalScore = 0.0
        var reasons: [String] = []

        // 1. Slot requirement satisfaction
        let slotScore = scoreSlotRequirements(items: items, rule: rule)
        totalScore += slotScore.value
        reasons.append(slotScore.reason)

        // 2. Hero piece identification (most visually distinct item)
        let heroScore = scoreHeroPiece(items: items)
        totalScore += heroScore.value
        reasons.append(heroScore.reason)

        // 3. Two-of-three color matching
        let colorMatchScore = scoreTwoOfThreeMatch(items: items)
        totalScore += colorMatchScore.value
        reasons.append(colorMatchScore.reason)

        // 4. Third piece rule (outerwear/accessory elevates a basic outfit)
        let thirdPieceScore = scoreThirdPiece(items: items)
        totalScore += thirdPieceScore.value
        reasons.append(thirdPieceScore.reason)

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            reasoning: reasons.joined(separator: ". ")
        )
    }

    // MARK: - Slot Requirements

    private func scoreSlotRequirements(items: [WardrobeItem], rule: StyleRule) -> (value: Double, reason: String) {
        let requirements = rule.slotRequirements
        let requiredSlots = requirements.filter(\.isRequired)
        let optionalSlots = requirements.filter { !$0.isRequired }

        var satisfiedRequired = 0
        var satisfiedOptional = 0

        for req in requiredSlots {
            let matchingItem = items.first { item in
                item.category.rawValue == req.category &&
                    (req.subcategories == nil || req.subcategories!.contains(item.subcategory.rawValue))
            }
            if matchingItem != nil { satisfiedRequired += 1 }
        }

        for req in optionalSlots {
            let matchingItem = items.first { item in
                item.category.rawValue == req.category &&
                    (req.subcategories == nil || req.subcategories!.contains(item.subcategory.rawValue))
            }
            if matchingItem != nil { satisfiedOptional += 1 }
        }

        let requiredRatio = requiredSlots.isEmpty ? 1.0 : Double(satisfiedRequired) / Double(requiredSlots.count)
        let optionalBonus = optionalSlots.isEmpty ? 0.0 : Double(satisfiedOptional) / Double(optionalSlots.count) * 0.1

        let value = requiredRatio * 0.35 + optionalBonus
        let reason = "\(satisfiedRequired)/\(requiredSlots.count) required slots filled"
        return (value, reason)
    }

    // MARK: - Hero Piece

    private func scoreHeroPiece(items: [WardrobeItem]) -> (value: Double, reason: String) {
        // Hero piece = item with most saturated/distinctive colors OR outerwear piece
        let hasOuterwear = items.contains { $0.category == .outerwear }
        let hasDress = items.contains { $0.category == .dress }

        if hasOuterwear || hasDress {
            return (0.2, "Clear hero piece anchors the outfit")
        }

        // Check for a color-standout item
        let avgSaturation = items.flatMap(\.dominantColors).map(\.saturation).reduce(0.0, +)
            / Double(max(1, items.flatMap(\.dominantColors).count))

        let standoutItem = items.first { item in
            let maxSat = item.dominantColors.map(\.saturation).max() ?? 0
            return maxSat > avgSaturation + 0.15
        }

        if standoutItem != nil {
            return (0.15, "One item stands out as the color focal point")
        }

        return (0.08, "No clear hero piece — outfit may lack a focal point")
    }

    // MARK: - Two-of-Three Color Match

    private func scoreTwoOfThreeMatch(items: [WardrobeItem]) -> (value: Double, reason: String) {
        guard items.count >= 2 else { return (0.1, "Too few items for color matching") }

        let families = items.compactMap { $0.dominantColors.first?.colorFamily }
        let familyCounts = Dictionary(grouping: families, by: { $0 }).mapValues(\.count)

        // Check if at least 2 items share a color family
        let maxShared = familyCounts.values.max() ?? 0

        if maxShared >= 2 {
            return (0.25, "\(maxShared) items share a color family — cohesive")
        }

        // Check if items share neutral families
        let neutralFamilies = items.flatMap(\.dominantColors).filter(\.isNeutral).map(\.colorFamily)
        let neutralShared = Dictionary(grouping: neutralFamilies, by: { $0 }).values.map(\.count).max() ?? 0

        if neutralShared >= 2 {
            return (0.2, "Items connected through shared neutrals")
        }

        return (0.08, "Items lack a shared color thread")
    }

    // MARK: - Third Piece Rule

    private func scoreThirdPiece(items: [WardrobeItem]) -> (value: Double, reason: String) {
        let hasTop = items.contains { $0.category == .top }
        let hasBottom = items.contains { $0.category == .bottom }
        let hasOuterwear = items.contains { $0.category == .outerwear }
        let hasAccessory = items.contains { $0.category == .accessory }

        if hasTop && hasBottom && (hasOuterwear || hasAccessory) {
            return (0.2, "Third piece elevates the outfit")
        }

        if hasTop && hasBottom {
            return (0.1, "Solid base — a jacket or accessory would elevate")
        }

        return (0.05, "Incomplete formula")
    }
}
