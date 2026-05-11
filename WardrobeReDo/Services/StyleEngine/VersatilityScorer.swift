import Foundation

/// Scores outfit versatility: item frequency penalty, novel
/// combination bonus, least-worn item bonus. Encourages using the
/// full wardrobe.
///
/// **Build 6 — novel combination bonus.** Earlier builds documented
/// this bonus but never implemented it. Now we generate the
/// unordered item-pair set for the candidate outfit and compare
/// against `context.recentOutfitItemPairs` (pairs seen in the
/// user's last 30 saved outfits): the lower the overlap, the
/// higher the novelty contribution (up to +0.20 of the dimension's
/// [0,1] output). When `recentOutfitItemPairs` is empty (fresh
/// user, no saved outfits yet) the sub-component reports
/// `noveltyCovered = false` and contributes nothing — the dimension
/// still scores from frequency + recency + category breadth, just
/// without the novelty axis.
struct VersatilityScorer: OutfitScorer {
    let dimension = ScoringDimension.versatility

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

        // 5. Novel combination bonus (build 6). Generate every
        // unordered pair of item IDs in the candidate outfit and
        // measure how many of those pairs the user has worn
        // together in the last 30 saved outfits. `coverage = 0`
        // when we have no historical pairs to compare against —
        // the OutfitScore aggregator handles that by excluding the
        // dimension from the weighted average.
        let novelty = noveltyScore(items: items, recent: context.recentOutfitItemPairs)
        if let bonus = novelty.bonus {
            totalScore += bonus
            reasons.append(novelty.reason)
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            coverage: novelty.coverage,
            reasoning: reasons.joined(separator: ". ")
        )
    }

    /// Computes the novelty sub-score for a candidate outfit.
    /// Returns:
    ///   • `bonus`: `Double?` — `nil` when there's no history to
    ///     compare against. Up to `+0.20` when zero pairs overlap.
    ///   • `reason`: human-readable text appended to the
    ///     reasoning string.
    ///   • `coverage`: `1.0` when novelty contributed to the score,
    ///     `0.0` when the user has no recent outfits to compare
    ///     against (so the dimension's overall coverage isn't
    ///     polluted by a missing input).
    private func noveltyScore(
        items: [WardrobeItem],
        recent: Set<UnorderedItemPair>
    ) -> (bonus: Double?, reason: String, coverage: Double) {
        // Need ≥2 items to generate a pair. Outfits with one item
        // (a dress, a jumpsuit) skip novelty.
        guard items.count >= 2 else {
            return (nil, "", 1.0)  // single-item outfit; not a novelty miss
        }
        guard !recent.isEmpty else {
            return (nil, "", 0.0)  // no history; novelty axis has no signal
        }
        let pairs = generatePairs(itemIDs: items.map(\.id))
        let seen = pairs.filter { recent.contains($0) }.count
        let novelty = 1.0 - Double(seen) / Double(pairs.count)
        let bonus = novelty * 0.20
        let reason: String
        if seen == 0 {
            reason = "Brand-new pairing — never worn together before"
        } else if novelty >= 0.5 {
            reason = "Mostly novel pairings (\(seen)/\(pairs.count) seen recently)"
        } else if novelty > 0 {
            reason = "Some novelty (\(seen)/\(pairs.count) pairs already worn together)"
        } else {
            reason = "Familiar pairing — every pair seen in recent outfits"
        }
        return (bonus, reason, 1.0)
    }

    private func generatePairs(itemIDs: [UUID]) -> [UnorderedItemPair] {
        var pairs: [UnorderedItemPair] = []
        for i in 0 ..< itemIDs.count {
            for j in (i + 1) ..< itemIDs.count {
                pairs.append(UnorderedItemPair(itemIDs[i], itemIDs[j]))
            }
        }
        return pairs
    }
}
