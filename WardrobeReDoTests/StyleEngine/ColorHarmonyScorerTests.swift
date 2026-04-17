import Testing
@testable import WardrobeReDo

// MARK: - ColorHarmonyScorer Tests

private let scorer = ColorHarmonyScorer()
private let archetype = TestFixtures.makeStyleArchetype()
private let rule = TestFixtures.makeStyleRule()
private let context = TestFixtures.makeScoringContext()

@Test func noColorsDefaultsToHalf() {
    let items = [TestFixtures.makeWardrobeItem(dominantColors: [])]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value == 0.5)
}

@Test func singleColorFamilyMonochromatic() {
    let blue1 = TestFixtures.makeColorProfile(hex: "#3366CC", hue: 220, saturation: 0.6, lightness: 0.4,
                                               percentage: 0.8, colorFamily: "blue")
    let blue2 = TestFixtures.makeColorProfile(hex: "#4477DD", hue: 225, saturation: 0.6, lightness: 0.5,
                                               percentage: 0.8, colorFamily: "blue")
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [blue1]),
        TestFixtures.makeWardrobeItem(dominantColors: [blue2]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value > 0.4)
}

@Test func twoColorFamiliesScoreWell() {
    let blue = TestFixtures.makeColorProfile(colorFamily: "blue")
    let white = TestFixtures.makeColorProfile(hex: "#FFFFFF", hue: 0, saturation: 0, lightness: 0.95,
                                               percentage: 0.6, colorFamily: "white", isNeutral: true)
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [blue]),
        TestFixtures.makeWardrobeItem(dominantColors: [white]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value > 0.3)
}

@Test func threeColorFamiliesIdealPalette() {
    let blue = TestFixtures.makeColorProfile(hue: 220, percentage: 0.6, colorFamily: "blue")
    let gray = TestFixtures.makeColorProfile(hex: "#888888", hue: 0, saturation: 0.05, lightness: 0.5,
                                              percentage: 0.3, colorFamily: "gray", isNeutral: true)
    let white = TestFixtures.makeColorProfile(hex: "#FFFFFF", hue: 0, saturation: 0, lightness: 0.95,
                                               percentage: 0.1, colorFamily: "white", isNeutral: true)
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [blue]),
        TestFixtures.makeWardrobeItem(dominantColors: [gray]),
        TestFixtures.makeWardrobeItem(dominantColors: [white]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value > 0.3)
}

@Test func fivePlusColorFamiliesPenalized() {
    let families = ["red", "blue", "green", "yellow", "purple"]
    let items = families.map { family in
        TestFixtures.makeWardrobeItem(dominantColors: [
            TestFixtures.makeColorProfile(colorFamily: family)
        ])
    }
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // 5+ families gets only 0.05 for the count dimension
    #expect(result.value < 0.7)
}

@Test func goodDominantColorProportion() {
    // 60% dominant color -> bonus
    let dominant = TestFixtures.makeColorProfile(percentage: 0.65, colorFamily: "blue")
    let accent = TestFixtures.makeColorProfile(hex: "#CCCCCC", percentage: 0.35, colorFamily: "gray", isNeutral: true)
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [dominant]),
        TestFixtures.makeWardrobeItem(dominantColors: [accent]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value > 0.3)
}

@Test func goodLightnessDarkContrastScoresHigher() {
    let dark = TestFixtures.makeColorProfile(lightness: 0.2, colorFamily: "navy")
    let light = TestFixtures.makeColorProfile(hex: "#EEEEEE", lightness: 0.9, colorFamily: "white", isNeutral: true)
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [dark]),
        TestFixtures.makeWardrobeItem(dominantColors: [light]),
    ]

    let lowContrast1 = TestFixtures.makeColorProfile(lightness: 0.4, colorFamily: "gray")
    let lowContrast2 = TestFixtures.makeColorProfile(lightness: 0.45, colorFamily: "gray")
    let flatItems = [
        TestFixtures.makeWardrobeItem(dominantColors: [lowContrast1]),
        TestFixtures.makeWardrobeItem(dominantColors: [lowContrast2]),
    ]

    let highContrastResult = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    let lowContrastResult = scorer.score(items: flatItems, archetype: archetype, rule: rule, context: context)

    #expect(highContrastResult.value > lowContrastResult.value)
}

@Test func lowLightnessContrastLooksFlat() {
    let c1 = TestFixtures.makeColorProfile(lightness: 0.4, colorFamily: "blue")
    let c2 = TestFixtures.makeColorProfile(lightness: 0.45, colorFamily: "blue")
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [c1]),
        TestFixtures.makeWardrobeItem(dominantColors: [c2]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    // Contrast < 0.15 means "flat"
    #expect(result.reasoning.contains("flat") || result.value < 0.9)
}

@Test func saturationCoherenceBonus() {
    // Low saturation range -> bonus
    let c1 = TestFixtures.makeColorProfile(saturation: 0.5, colorFamily: "blue")
    let c2 = TestFixtures.makeColorProfile(saturation: 0.55, colorFamily: "navy")
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [c1]),
        TestFixtures.makeWardrobeItem(dominantColors: [c2]),
    ]
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.reasoning.contains("Cohesive saturation") || result.value > 0.3)
}

@Test func complementaryHuesDetected() {
    // Hues ~180 degrees apart = complementary
    let c1 = TestFixtures.makeColorProfile(hue: 0, saturation: 0.7, colorFamily: "red")
    let c2 = TestFixtures.makeColorProfile(hue: 180, saturation: 0.7, colorFamily: "teal")
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [c1]),
        TestFixtures.makeWardrobeItem(dominantColors: [c2]),
    ]

    let complementaryRule = TestFixtures.makeStyleRule(preferredHarmony: "complementary")
    let result = scorer.score(items: items, archetype: archetype, rule: complementaryRule, context: context)
    #expect(result.reasoning.contains("complementary") || result.reasoning.contains("Complementary"))
}

@Test func analogousHuesDetected() {
    // Hues within 60 degrees = analogous
    let c1 = TestFixtures.makeColorProfile(hue: 200, saturation: 0.6, colorFamily: "blue")
    let c2 = TestFixtures.makeColorProfile(hue: 230, saturation: 0.6, colorFamily: "blue")
    let items = [
        TestFixtures.makeWardrobeItem(dominantColors: [c1]),
        TestFixtures.makeWardrobeItem(dominantColors: [c2]),
    ]
    let analogousRule = TestFixtures.makeStyleRule(preferredHarmony: "analogous")
    let result = scorer.score(items: items, archetype: archetype, rule: analogousRule, context: context)
    #expect(result.value > 0.3)
}

@Test func scoreAlwaysWithinBounds() {
    // Extreme inputs should still produce 0-1 range
    let items = (0..<10).map { _ in
        TestFixtures.makeWardrobeItem(dominantColors: [
            TestFixtures.makeColorProfile(hue: Double.random(in: 0...360),
                                           saturation: Double.random(in: 0...1),
                                           lightness: Double.random(in: 0...1),
                                           colorFamily: ["red", "blue", "green"].randomElement()!)
        ])
    }
    let result = scorer.score(items: items, archetype: archetype, rule: rule, context: context)
    #expect(result.value >= 0.0 && result.value <= 1.0)
}
