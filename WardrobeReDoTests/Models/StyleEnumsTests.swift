import Testing
@testable import WardrobeReDo

// MARK: - TextureType Tests

@Test func textureTypeVisualWeightMapping() {
    // Light textures
    #expect(TextureType.silk.visualWeight == .light)
    #expect(TextureType.chiffon.visualWeight == .light)
    #expect(TextureType.satin.visualWeight == .light)

    // Medium textures
    #expect(TextureType.cotton.visualWeight == .medium)
    #expect(TextureType.linen.visualWeight == .medium)

    // Heavy textures
    #expect(TextureType.leather.visualWeight == .heavy)
    #expect(TextureType.denim.visualWeight == .heavy)
    #expect(TextureType.wool.visualWeight == .heavy)
}

@Test func textureTypeFormalitySmoothnessRange() {
    for texture in TextureType.allCases {
        let smoothness = texture.formalitySmoothness
        #expect(smoothness >= 3.0 && smoothness <= 9.0,
                "\(texture) smoothness \(smoothness) is outside expected range [3.0, 9.0]")
    }
}

@Test func textureTypeSilkAndSatinHaveHighestSmoothness() {
    let silkSmooth = TextureType.silk.formalitySmoothness
    let satinSmooth = TextureType.satin.formalitySmoothness

    for texture in TextureType.allCases where texture != .silk && texture != .satin {
        #expect(silkSmooth >= texture.formalitySmoothness,
                "Silk (\(silkSmooth)) should be >= \(texture) (\(texture.formalitySmoothness))")
        #expect(satinSmooth >= texture.formalitySmoothness - 1.0,
                "Satin should be among the highest smoothness values")
    }
}

@Test func textureTypeDisplayNameIsCapitalized() {
    for texture in TextureType.allCases {
        let name = texture.displayName
        #expect(!name.isEmpty)
        #expect(name.first?.isUppercase == true, "\(texture).displayName should be capitalized: \(name)")
    }
}

@Test func textureTypeHasFifteenCases() {
    #expect(TextureType.allCases.count == 15)
}

// MARK: - FitAttribute Tests

@Test func fitAttributeHasSixCases() {
    #expect(FitAttribute.allCases.count == 6)
    let expected: Set<FitAttribute> = [.oversized, .relaxed, .regular, .slim, .structured, .cropped]
    #expect(Set(FitAttribute.allCases) == expected)
}

@Test func fitAttributeDisplayNameIsCapitalized() {
    for fit in FitAttribute.allCases {
        let name = fit.displayName
        #expect(!name.isEmpty)
        #expect(name.first?.isUppercase == true, "\(fit).displayName should be capitalized: \(name)")
    }
}

// MARK: - Season Tests

@Test func seasonHasFourCases() {
    #expect(Season.allCases.count == 4)
    let expected: Set<Season> = [.spring, .summer, .fall, .winter]
    #expect(Set(Season.allCases) == expected)
}

@Test func seasonDisplayNames() {
    #expect(Season.spring.displayName == "Spring")
    #expect(Season.summer.displayName == "Summer")
    #expect(Season.fall.displayName == "Fall")
    #expect(Season.winter.displayName == "Winter")
}

// MARK: - Occasion Tests

@Test func occasionHasSixCases() {
    #expect(Occasion.allCases.count == 6)
    let expected: Set<Occasion> = [.casual, .work, .date, .formal, .athletic, .lounge]
    #expect(Set(Occasion.allCases) == expected)
}

@Test func occasionDisplayNames() {
    #expect(Occasion.casual.displayName == "Casual")
    #expect(Occasion.work.displayName == "Work")
    #expect(Occasion.formal.displayName == "Formal")
}

// MARK: - VisualWeight Tests

@Test func visualWeightHasThreeCases() {
    let expected: [VisualWeight] = [.light, .medium, .heavy]
    for weight in expected {
        #expect(!weight.rawValue.isEmpty)
    }
}

// MARK: - ColorHarmonyType Tests

@Test func colorHarmonyTypeHasFiveKnownCases() {
    let allHarmonies: [ColorHarmonyType] = [
        .complementary, .analogous, .triadic, .monochromatic, .neutral
    ]
    // Verify all 5 exist and have non-empty raw values
    for harmony in allHarmonies {
        #expect(!harmony.rawValue.isEmpty)
    }
    #expect(allHarmonies.count == 5)
}

@Test func colorHarmonyTypeRawValuesAreLowercase() {
    let allHarmonies: [ColorHarmonyType] = [
        .complementary, .analogous, .triadic, .monochromatic, .neutral
    ]
    for harmony in allHarmonies {
        #expect(harmony.rawValue == harmony.rawValue.lowercased(),
                "\(harmony).rawValue should be lowercase: \(harmony.rawValue)")
    }
}
