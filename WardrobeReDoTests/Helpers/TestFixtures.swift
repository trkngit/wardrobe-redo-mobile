import Foundation
@testable import WardrobeReDo

// MARK: - Test Fixtures

/// Deterministic factory methods for building test data.
/// All return `Sendable` types matching the production models exactly.
enum TestFixtures {

    // MARK: - ColorProfile

    static func makeColorProfile(
        hex: String = "#3366CC",
        hue: Double = 220,
        saturation: Double = 0.6,
        lightness: Double = 0.4,
        percentage: Double = 0.8,
        colorFamily: String = "blue",
        isNeutral: Bool = false
    ) -> ColorProfile {
        ColorProfile(
            hex: hex,
            hue: hue,
            saturation: saturation,
            lightness: lightness,
            percentage: percentage,
            colorFamily: colorFamily,
            isNeutral: isNeutral
        )
    }

    // MARK: - WardrobeItem

    static func makeWardrobeItem(
        id: UUID = UUID(),
        userId: UUID = UUID(),
        category: ClothingCategory = .top,
        subcategory: ClothingSubcategory = .tshirt,
        dominantColors: [ColorProfile]? = nil,
        texture: TextureType? = .cotton,
        fitAttribute: FitAttribute? = .regular,
        formalityComputed: Double? = 0.3,
        seasons: [Season] = Season.allCases.map { $0 },
        occasions: [Occasion] = [.casual],
        wearCount: Int = 0,
        isArchived: Bool = false,
        maskedImagePath: String? = nil,
        extractionConfidence: ExtractionConfidence? = nil
    ) -> WardrobeItem {
        WardrobeItem(
            id: id,
            userId: userId,
            imagePath: "images/\(id).jpg",
            thumbnailPath: "thumbnails/\(id).jpg",
            maskedImagePath: maskedImagePath,
            extractionConfidence: extractionConfidence,
            category: category,
            subcategory: subcategory,
            dominantColors: dominantColors ?? [makeColorProfile()],
            texture: texture,
            fitAttribute: fitAttribute,
            formalityComponents: nil,
            formalityComputed: formalityComputed,
            seasons: seasons,
            occasions: occasions,
            visualWeight: texture?.visualWeight,
            wearCount: wearCount,
            lastWornAt: nil,
            isArchived: isArchived,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - StyleArchetype

    static func makeStyleArchetype(
        id: UUID = UUID(),
        name: String = "classic_casual",
        family: String = "classic",
        editorialName: String = "Classic Casual",
        formalityMin: Double = 0.2,
        formalityMax: Double = 0.5,
        seasons: [String] = ["spring", "summer", "fall", "winter"],
        occasions: [String] = ["casual"],
        colorPreferences: ArchetypeColorPreferences? = nil,
        texturePreferences: ArchetypeTexturePreferences? = nil,
        proportionPreferences: ArchetypeProportionPreferences? = nil
    ) -> StyleArchetype {
        StyleArchetype(
            id: id,
            name: name,
            family: family,
            editorialName: editorialName,
            description: "A versatile everyday look",
            formalityMin: formalityMin,
            formalityMax: formalityMax,
            seasons: seasons,
            occasions: occasions,
            moodKeywords: ["relaxed", "easy"],
            colorPreferences: colorPreferences,
            texturePreferences: texturePreferences,
            proportionPreferences: proportionPreferences
        )
    }

    // MARK: - StyleRule

    static func makeStyleRule(
        id: UUID = UUID(),
        archetypeId: UUID = UUID(),
        slotRequirements: [SlotRequirement]? = nil,
        weight: Double = 1.0,
        boostConditions: BoostConditions? = nil,
        penaltyConditions: PenaltyConditions? = nil,
        preferredHarmony: String = "analogous",
        proportionRule: ProportionRule? = nil,
        textureRule: TextureRule? = nil
    ) -> StyleRule {
        StyleRule(
            id: id,
            archetypeId: archetypeId,
            slotRequirements: slotRequirements ?? [
                SlotRequirement(category: "top", subcategories: nil, isRequired: true),
                SlotRequirement(category: "bottom", subcategories: nil, isRequired: true),
                SlotRequirement(category: "shoe", subcategories: nil, isRequired: false),
            ],
            weight: weight,
            boostConditions: boostConditions,
            penaltyConditions: penaltyConditions,
            preferredHarmony: preferredHarmony,
            proportionRule: proportionRule,
            textureRule: textureRule
        )
    }

    // MARK: - ScoringContext

    static func makeScoringContext(
        season: Season = .spring,
        occasion: Occasion = .casual,
        dayOfWeek: String = "wednesday",
        wardrobeItemCount: Int = 20,
        recentOutfitItemIds: Set<UUID> = []
    ) -> ScoringContext {
        ScoringContext(
            season: season,
            occasion: occasion,
            dayOfWeek: dayOfWeek,
            wardrobeItemCount: wardrobeItemCount,
            recentOutfitItemIds: recentOutfitItemIds
        )
    }

    // MARK: - Outfit

    static func makeOutfit(
        id: UUID = UUID(),
        userId: UUID = UUID(),
        archetypeId: UUID = UUID(),
        editorialName: String = "Weekend Essential",
        score: Double = 0.72,
        scoreBreakdown: ScoreBreakdown? = nil,
        reaction: String? = nil,
        isWorn: Bool = false
    ) -> Outfit {
        Outfit(
            id: id,
            userId: userId,
            archetypeId: archetypeId,
            editorialName: editorialName,
            editorialDescription: nil,
            date: "2025-04-15",
            score: score,
            scoreBreakdown: scoreBreakdown,
            reaction: reaction,
            isWorn: isWorn,
            createdAt: Date()
        )
    }

    // MARK: - DailyOutfit

    static func makeDailyOutfit(
        outfit: Outfit? = nil,
        slots: [OutfitSlot]? = nil,
        items: [WardrobeItem]? = nil
    ) -> DailyOutfit {
        let resolvedOutfit = outfit ?? makeOutfit()
        let resolvedItems = items ?? [
            makeWardrobeItem(category: .top, subcategory: .tshirt),
            makeWardrobeItem(category: .bottom, subcategory: .jeans),
            makeWardrobeItem(category: .shoe, subcategory: .sneakers),
        ]
        let resolvedSlots = slots ?? resolvedItems.enumerated().map { index, item in
            OutfitSlot(
                id: UUID(),
                outfitId: resolvedOutfit.id,
                wardrobeItemId: item.id,
                slotName: item.category.rawValue,
                role: index == 0 ? "hero" : "supporting"
            )
        }
        return DailyOutfit(
            outfit: resolvedOutfit,
            slots: resolvedSlots,
            items: resolvedItems
        )
    }

    // MARK: - ScoreBreakdown

    static func makeScoreBreakdown(
        proportion: Double = 0.7,
        colorHarmony: Double = 0.8,
        textureMix: Double = 0.6,
        formality: Double = 0.75,
        formula: Double = 0.65,
        versatility: Double = 0.7,
        occasion: Double = 0.8
    ) -> ScoreBreakdown {
        ScoreBreakdown(
            proportion: proportion,
            colorHarmony: colorHarmony,
            textureMix: textureMix,
            formality: formality,
            formula: formula,
            versatility: versatility,
            occasion: occasion
        )
    }

    // MARK: - Profile

    static func makeProfile(
        id: UUID = UUID(),
        displayName: String = "Test User",
        onboardingCompleted: Bool = true,
        stylePreferences: StylePreferences? = nil
    ) -> Profile {
        Profile(
            id: id,
            displayName: displayName,
            tier: "free",
            stylePreferences: stylePreferences,
            onboardingCompleted: onboardingCompleted,
            timezone: "America/New_York",
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
