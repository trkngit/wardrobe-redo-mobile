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

        // 2. Uniqueness-weighted recent-usage penalty (Build 49).
        //
        // The old rule penalized ANY recently-worn item uniformly, so a
        // plain white tee dragged a candidate's score down exactly as
        // hard as a sequined jacket. The TF49 ask (#7): "a t-shirt worn
        // several days in a row isn't a problem, but more 'unique' pieces
        // shouldn't be worn back-to-back." So the penalty now scales with
        // each recently-worn item's `uniqueness` — basics barely dent the
        // score; statement pieces tank it. The 0.30 budget is unchanged,
        // so the dimension's overall [0,1] range is preserved.
        let recentIds = context.recentOutfitItemIds
        let recentlyUsed = items.filter { recentIds.contains($0.id) }

        if recentlyUsed.isEmpty {
            totalScore += 0.3
            reasons.append("All fresh — no recent repeats")
        } else {
            // Sum the uniqueness of every recently-worn item. One
            // fully-unique repeat (≈1.0) eats almost the whole 0.30
            // budget (penalty 0.28 → contribution 0.02); a fully-basic
            // repeat (≈0.0) costs nothing. Multiple unique repeats
            // saturate at the 0.02 floor.
            let uniquenessSum = recentlyUsed.reduce(0.0) { $0 + Self.uniqueness($1) }
            let penalty = min(0.28, uniquenessSum * 0.28)
            totalScore += max(0.02, 0.30 - penalty)
            if uniquenessSum >= 0.6 {
                reasons.append("Repeats a statement piece worn recently — penalized")
            } else if uniquenessSum > 0 {
                reasons.append("Repeats mostly basics — light recency penalty")
            } else {
                reasons.append("Recent repeats are wardrobe staples — no penalty")
            }
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
        //
        // Vibe modulation: `.bold` outfits get a 1.5× novelty
        // multiplier (rewarding unusual pairings); `.safe`
        // outfits get 0.5× (de-emphasizing novelty in favour of
        // familiarity). See `VibePreset.noveltyRewardMultiplier`.
        let novelty = noveltyScore(items: items, recent: context.recentOutfitItemPairs)
        if let bonus = novelty.bonus {
            totalScore += bonus * context.vibePreset.noveltyRewardMultiplier
            reasons.append(novelty.reason)
        }

        // 6. Exact-combination cooldown (Build 49, TF49 #6). The
        // pair-novelty bonus above rewards *fresh pairings*, but it can't
        // stop a whole previously-suggested outfit from resurfacing a few
        // days later (every pair in it is "familiar", not novel — a soft
        // signal). The user wants a hard floor: don't re-propose the exact
        // same combination within two weeks. `recentOutfitItemSets` holds
        // the full item-sets of outfits suggested or worn in the last 14
        // days; if this candidate's set is already in there, subtract a
        // large fixed amount so it sinks below any genuinely new option.
        // It's a penalty, not a ban — if the wardrobe is so small that no
        // fresh combination exists, the penalized outfit can still surface
        // (clamped at 0), just ranked last.
        if !context.recentOutfitItemSets.isEmpty {
            let candidateSet = Set(items.map(\.id))
            if context.recentOutfitItemSets.contains(candidateSet) {
                totalScore -= 0.5
                reasons.append("Exact combination suggested in the last 2 weeks — strongly penalized")
            }
        }

        return DimensionScore(
            dimension: dimension,
            value: min(1.0, max(0.0, totalScore)),
            coverage: novelty.coverage,
            reasoning: reasons.joined(separator: ". ")
        )
    }

    /// A garment's "statement-ness" in `[0, 1]` (Build 49, TF49 #7).
    /// Low ≈ a basic/staple that can repeat day-to-day without anyone
    /// noticing (a plain neutral tee worn often, fits many occasions);
    /// high ≈ a distinctive piece that reads as "the same outfit again"
    /// if worn back-to-back (rarely worn, bold colour, niche use).
    ///
    /// Deliberately a **pure function of fields already on the item** —
    /// no dates, no `Date()`, no I/O — so the scorer stays deterministic
    /// and trivially unit-testable. The three signals are averaged with
    /// equal weight; each maps to `[0, 1]` where 1 = more unique:
    ///   • **Wear frequency** — heavily-worn items are proven staples.
    ///   • **Colour neutrality** — a wardrobe of mostly-neutral colours
    ///     reads as basics; bold/non-neutral pieces stand out.
    ///   • **Occasion breadth** — something valid for many occasions is
    ///     a workhorse; a 1–2-occasion piece is a special-purpose item.
    static func uniqueness(_ item: WardrobeItem) -> Double {
        // Wear frequency: 15+ wears → staple (0); 6–14 → mid; <6 → fresh (1).
        let wearFactor: Double = item.wearCount >= 15 ? 0.0
            : item.wearCount >= 6 ? 0.35 : 1.0

        // Colour neutrality: majority-neutral → basic (0); otherwise bold (1).
        // No colours on record → neutral midpoint so a missing palette
        // neither rewards nor punishes.
        let neutralFactor: Double
        if item.dominantColors.isEmpty {
            neutralFactor = 0.5
        } else {
            let neutralCount = item.dominantColors.filter(\.isNeutral).count
            let neutralShare = Double(neutralCount) / Double(item.dominantColors.count)
            neutralFactor = neutralShare >= 0.5 ? 0.0 : 1.0
        }

        // Occasion breadth: 4+ → versatile (0); 3 → mid; ≤2 → niche (1).
        let occasionFactor: Double = item.occasions.count >= 4 ? 0.0
            : item.occasions.count >= 3 ? 0.4 : 1.0

        return (wearFactor + neutralFactor + occasionFactor) / 3.0
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
