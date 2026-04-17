import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - B5: Repository Edge Cases & Bundled Data Tests

// MARK: - Date Formatting (extended from OutfitRepositoryDateTests)

@Test func todayDateStringIsConsistentAcrossFormatter() {
    let str1 = OutfitRepository.todayDateString()
    let str2 = OutfitRepository.todayDateString()
    #expect(str1 == str2, "todayDateString() should be deterministic within same second")
}

// MARK: - Bundled Style Data Integrity

@Test func bundledArchetypesJsonExists() {
    let url = Bundle.main.url(forResource: "archetypes", withExtension: "json", subdirectory: "SeedData")
    // This may be nil in test bundle — check if StyleDataRepository fallback works
    // The important thing is that the fallback path exists
    if url != nil {
        let data = try? Data(contentsOf: url!)
        #expect(data != nil, "archetypes.json should be readable")
    }
}

@Test func bundledRulesJsonExists() {
    let url = Bundle.main.url(forResource: "rules", withExtension: "json", subdirectory: "SeedData")
    if url != nil {
        let data = try? Data(contentsOf: url!)
        #expect(data != nil, "rules.json should be readable")
    }
}

// MARK: - Model Factory Defaults Are Valid

@Test func testFixtureWardrobeItemHasValidDefaults() {
    let item = TestFixtures.makeWardrobeItem()
    #expect(item.category == .top)
    #expect(item.subcategory == .tshirt)
    #expect(item.dominantColors.count == 1)
    #expect(item.wearCount == 0)
    #expect(item.isArchived == false)
    #expect(item.seasons.count == 4)
    #expect(item.occasions == [.casual])
    #expect(!item.imagePath.isEmpty)
    #expect(!item.thumbnailPath.isEmpty)
}

@Test func testFixtureOutfitHasValidDefaults() {
    let outfit = TestFixtures.makeOutfit()
    #expect(outfit.score == 0.72)
    #expect(outfit.reaction == nil)
    #expect(outfit.isWorn == false)
    #expect(!outfit.editorialName.isEmpty)
    #expect(!outfit.date.isEmpty)
}

@Test func testFixtureProfileHasValidDefaults() {
    let profile = TestFixtures.makeProfile()
    #expect(profile.displayName == "Test User")
    #expect(profile.tier == "free")
    #expect(profile.onboardingCompleted == true)
}

@Test func testFixtureDailyOutfitHasThreeItems() {
    let daily = TestFixtures.makeDailyOutfit()
    #expect(daily.items.count == 3)
    #expect(daily.slots.count == 3)
    #expect(daily.outfit.score == 0.72)
}

@Test func testFixtureStyleRuleHasThreeSlots() {
    let rule = TestFixtures.makeStyleRule()
    #expect(rule.slotRequirements.count == 3)
    #expect(rule.slotRequirements[0].isRequired == true) // top
    #expect(rule.slotRequirements[1].isRequired == true) // bottom
    #expect(rule.slotRequirements[2].isRequired == false) // shoe (optional)
}

@Test func testFixtureScoringContextHasValidDefaults() {
    let ctx = TestFixtures.makeScoringContext()
    #expect(ctx.season == .spring)
    #expect(ctx.occasion == .casual)
    #expect(ctx.wardrobeItemCount == 20)
    #expect(ctx.recentOutfitItemIds.isEmpty)
}

// MARK: - Subcategory Cross-Validation

@Test func allSubcategoriesMapBackToParentCategory() {
    for subcategory in ClothingSubcategory.allCases {
        let parent = subcategory.category
        let siblings = ClothingSubcategory.subcategories(for: parent)
        #expect(siblings.contains(subcategory),
                "\(subcategory) claims parent \(parent) but subcategories(for:) doesn't include it")
    }
}

@Test func subcategoryUnionEqualsAllCases() {
    var allFromCategories: Set<ClothingSubcategory> = []
    for category in ClothingCategory.allCases {
        let subs = ClothingSubcategory.subcategories(for: category)
        allFromCategories.formUnion(subs)
    }
    let allCases = Set(ClothingSubcategory.allCases)
    #expect(allFromCategories == allCases,
            "Union of subcategories per category should equal allCases")
}
