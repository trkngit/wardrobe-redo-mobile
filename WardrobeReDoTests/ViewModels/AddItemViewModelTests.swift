import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - AddItemViewModel Tests

@Test @MainActor func addItemInitialStepIsPhoto() {
    let vm = AddItemViewModel()
    #expect(vm.currentStep == .photo)
}

@Test @MainActor func addItemCanSaveFalseWithoutProcessedImage() {
    let vm = AddItemViewModel()
    #expect(vm.canSave == false)
}

@Test @MainActor func addItemCanSaveFalseWhileSaving() {
    let vm = AddItemViewModel()
    vm.isSaving = true
    #expect(vm.canSave == false)
}

@Test @MainActor func addItemOnCategoryChangedResetsSubcategoryWhenInvalid() {
    let vm = AddItemViewModel()
    vm.category = .top
    vm.subcategory = .tshirt
    // Switch to bottom — tshirt is not a valid bottom subcategory
    vm.category = .bottom
    vm.onCategoryChanged()
    #expect(vm.subcategory.category == .bottom)
}

@Test @MainActor func addItemOnCategoryChangedKeepsValidSubcategory() {
    let vm = AddItemViewModel()
    vm.category = .top
    vm.subcategory = .tshirt
    // Same category — should keep tshirt
    vm.onCategoryChanged()
    #expect(vm.subcategory == .tshirt)
}

@Test @MainActor func addItemResetRestoresDefaults() {
    let vm = AddItemViewModel()
    vm.category = .shoe
    vm.subcategory = .sneakers
    vm.texture = .leather
    vm.fitAttribute = .slim
    vm.errorMessage = "some error"
    vm.isSaving = true
    vm.didSave = true
    vm.currentStep = .details

    vm.reset()

    #expect(vm.currentStep == .photo)
    #expect(vm.category == .top)
    #expect(vm.subcategory == .tshirt)
    #expect(vm.texture == nil)
    #expect(vm.fitAttribute == nil)
    #expect(vm.errorMessage == nil)
    #expect(vm.isSaving == false)
    #expect(vm.didSave == false)
}

@Test @MainActor func addItemAvailableSubcategoriesMatchesCategory() {
    let vm = AddItemViewModel()
    vm.category = .top
    #expect(vm.availableSubcategories == ClothingSubcategory.subcategories(for: .top))

    vm.category = .shoe
    #expect(vm.availableSubcategories == ClothingSubcategory.subcategories(for: .shoe))
}

@Test @MainActor func addItemExtractedColorsEmptyWithoutProcessedImage() {
    let vm = AddItemViewModel()
    #expect(vm.extractedColors.isEmpty)
}

// MARK: - Additional Coverage

@Test @MainActor func addItemCanSaveTrueWithProcessedImage() {
    let vm = AddItemViewModel()
    vm.processedImage = ProcessedImage(
        originalData: Data([0xFF]),
        thumbnailData: Data([0xFF]),
        maskedData: nil,
        extractionConfidence: nil,
        dominantColors: []
    )
    #expect(vm.canSave == true)
}

@Test @MainActor func addItemDefaultSeasonsAreAllCases() {
    let vm = AddItemViewModel()
    #expect(vm.selectedSeasons == Set(Season.allCases))
}

@Test @MainActor func addItemDefaultOccasionIsCasual() {
    let vm = AddItemViewModel()
    #expect(vm.selectedOccasions == [.casual])
}

@Test @MainActor func addItemExtractedColorsPopulatedFromProcessedImage() {
    let vm = AddItemViewModel()
    let extractedColor = ExtractedColor(
        hex: "#3366CC",
        hue: 220,
        saturation: 0.6,
        lightness: 0.5,
        percentage: 0.75,
        colorFamily: "blue",
        isNeutral: false
    )
    vm.processedImage = ProcessedImage(
        originalData: Data([0xFF]),
        thumbnailData: Data([0xFF]),
        maskedData: nil,
        extractionConfidence: nil,
        dominantColors: [extractedColor]
    )
    #expect(vm.extractedColors.count == 1)
    #expect(vm.extractedColors.first?.colorFamily == "blue")
}
