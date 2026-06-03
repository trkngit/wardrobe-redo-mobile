import Foundation

/// Orchestrates the 7-dimension scoring engine.
/// Each outfit candidate is scored across all dimensions, producing
/// a weighted total score and per-dimension breakdown.
final class StyleEngineService {

    // MARK: - Scorers (one per dimension)

    private let scorers: [OutfitScorer] = [
        ProportionBalanceScorer(),
        ColorHarmonyScorer(),
        TextureMixScorer(),
        FormalityCoherenceScorer(),
        OutfitFormulaScorer(),
        VersatilityScorer(),
        OccasionContextScorer(),
    ]

    private let styleDataRepository = StyleDataRepository()

    // MARK: - Score a Single Outfit

    /// Score a candidate outfit against an archetype and rule.
    func scoreOutfit(
        items: [WardrobeItem],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> OutfitScore {
        let breakdown = scorers.map { scorer in
            scorer.score(items: items, archetype: archetype, rule: rule, context: context)
        }
        return OutfitScore(breakdown: breakdown, vibePreset: context.vibePreset)
    }

    // MARK: - Score Multiple Candidates

    /// Score an array of outfit candidates, returning them sorted by total score descending.
    func rankOutfits(
        candidates: [[WardrobeItem]],
        archetype: StyleArchetype,
        rule: StyleRule,
        context: ScoringContext
    ) -> [(items: [WardrobeItem], score: OutfitScore)] {
        candidates
            .map { items in
                (items: items, score: scoreOutfit(items: items, archetype: archetype, rule: rule, context: context))
            }
            .sorted { $0.score.totalScore > $1.score.totalScore }
    }

    // MARK: - Find Best Rule for Archetype

    /// Given a set of items and archetype, find the best-matching rule
    /// and return the score under that rule.
    func bestScore(
        items: [WardrobeItem],
        archetype: StyleArchetype,
        rules: [StyleRule],
        context: ScoringContext
    ) -> (rule: StyleRule, score: OutfitScore)? {
        let archetypeRules = rules.filter { $0.archetypeId == archetype.id }
        guard !archetypeRules.isEmpty else { return nil }

        return archetypeRules
            .map { rule in
                let score = scoreOutfit(items: items, archetype: archetype, rule: rule, context: context)
                // Weight the score by the rule's weight multiplier
                let weightedScore = OutfitScore(
                    breakdown: score.breakdown.map { dim in
                        DimensionScore(
                            dimension: dim.dimension,
                            value: dim.value,
                            coverage: dim.coverage,
                            reasoning: dim.reasoning
                        )
                    },
                    vibePreset: context.vibePreset
                )
                return (rule: rule, score: weightedScore)
            }
            .max { ($0.score.totalScore * $0.rule.weight) < ($1.score.totalScore * $1.rule.weight) }
    }

    // MARK: - Build Scoring Context

    /// Construct a ScoringContext from current conditions. Build 6
    /// added `vibe` so the caller can ask the engine to evaluate
    /// candidates against a specific strictness profile (Safe →
    /// Bold). Defaults to `.balanced` so existing call sites keep
    /// build-5 behaviour.
    static func buildContext(
        season: Season? = nil,
        occasion: Occasion = .casual,
        wardrobeSize: Int = 0,
        recentItemIds: Set<UUID> = [],
        recentItemPairs: Set<UnorderedItemPair> = [],
        recentItemSets: Set<Set<UUID>> = [],
        vibe: VibeStop = .balanced
    ) -> ScoringContext {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let dayOfWeek = dayNames[weekday - 1]

        let currentSeason = season ?? Self.currentSeason()

        return ScoringContext(
            season: currentSeason,
            occasion: occasion,
            dayOfWeek: dayOfWeek,
            wardrobeItemCount: wardrobeSize,
            recentOutfitItemIds: recentItemIds,
            recentOutfitItemPairs: recentItemPairs,
            recentOutfitItemSets: recentItemSets,
            vibePreset: VibePreset.preset(for: vibe)
        )
    }

    /// Determine current season from the calendar month.
    static func currentSeason() -> Season {
        let month = Calendar.current.component(.month, from: Date())
        switch month {
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        case 9, 10, 11: return .fall
        default: return .winter
        }
    }
}
