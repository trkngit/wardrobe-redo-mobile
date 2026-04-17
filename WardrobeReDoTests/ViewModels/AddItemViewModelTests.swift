import Foundation
import Testing
import UIKit
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
        extractionMethod: nil,
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
        extractionMethod: nil,
        dominantColors: [extractedColor]
    )
    #expect(vm.extractedColors.count == 1)
    #expect(vm.extractedColors.first?.colorFamily == "blue")
}

// MARK: - Phase 2: Camera flow + touch-up

/// Helper: a minimal 1×1 UIImage for camera-flow tests that just need a
/// non-nil `UIImage` to pass through the view model pipeline.
@MainActor
private func makePixelImage(color: UIColor = .systemBlue) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
    return renderer.image { ctx in
        color.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

@MainActor
private func makeProcessedImage(
    maskedData: Data? = Data([0xFF]),
    extractionMethod: ExtractionMethod? = nil
) -> ProcessedImage {
    ProcessedImage(
        originalData: Data([0xFF]),
        thumbnailData: Data([0xFF]),
        maskedData: maskedData,
        extractionConfidence: nil,
        extractionMethod: extractionMethod,
        dominantColors: []
    )
}

@Test @MainActor func addItemDefaultCaptureMethodIsLibrary() {
    let vm = AddItemViewModel()
    #expect(vm.captureMethod == .library)
    #expect(vm.isShowingCamera == false)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.isShowingTutorial == false)
}

@Test @MainActor func addItemBeginCameraCaptureShowsTutorialOnFirstRun() {
    UserDefaults.standard.removeObject(forKey: FirstRunTutorialView.hasSeenKey)
    let vm = AddItemViewModel()
    vm.beginCameraCapture()
    #expect(vm.captureMethod == .camera)
    #expect(vm.isShowingTutorial == true)
    #expect(vm.isShowingCamera == false)
}

@Test @MainActor func addItemBeginCameraCaptureSkipsTutorialWhenAlreadySeen() {
    UserDefaults.standard.set(true, forKey: FirstRunTutorialView.hasSeenKey)
    defer { UserDefaults.standard.removeObject(forKey: FirstRunTutorialView.hasSeenKey) }

    let vm = AddItemViewModel()
    vm.beginCameraCapture()
    #expect(vm.captureMethod == .camera)
    #expect(vm.isShowingTutorial == false)
    #expect(vm.isShowingCamera == true)
}

@Test @MainActor func addItemOnTutorialDismissedOpensCameraWhenCameraIntended() {
    let vm = AddItemViewModel()
    vm.captureMethod = .camera
    vm.isShowingTutorial = true

    vm.onTutorialDismissed()

    #expect(vm.isShowingTutorial == false)
    #expect(vm.isShowingCamera == true)
}

@Test @MainActor func addItemOnTutorialDismissedKeepsCameraClosedWhenLibrary() {
    let vm = AddItemViewModel()
    vm.captureMethod = .library
    vm.isShowingTutorial = true

    vm.onTutorialDismissed()

    #expect(vm.isShowingTutorial == false)
    #expect(vm.isShowingCamera == false)
}

@Test @MainActor func addItemOnCameraCancelledClosesCameraAndResetsMethod() {
    let vm = AddItemViewModel()
    vm.captureMethod = .camera
    vm.isShowingCamera = true

    vm.onCameraCancelled()

    #expect(vm.isShowingCamera == false)
    #expect(vm.captureMethod == .library)
}

@Test @MainActor func addItemOnCameraPhotoCapturedWithMaskShowsTouchup() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(maskedData: Data([0xAB]))
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true
    vm.currentStep = .photo

    await vm.onCameraPhotoCaptured(makePixelImage())

    #expect(vm.isShowingCamera == false)
    #expect(vm.isShowingTouchup == true)
    #expect(vm.processedImage != nil)
    #expect(vm.processedImage?.maskedData != nil)
    #expect(mockImage.processImageCallCount == 1)
}

@Test @MainActor func addItemOnCameraPhotoCapturedWithoutMaskSkipsTouchup() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(maskedData: nil)
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true

    await vm.onCameraPhotoCaptured(makePixelImage())

    #expect(vm.isShowingCamera == false)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.currentStep == .details)
}

@Test @MainActor func addItemOnCameraPhotoCapturedProcessFailureSurfacesError() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = nil
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true

    await vm.onCameraPhotoCaptured(makePixelImage())

    #expect(vm.errorMessage != nil)
    #expect(vm.currentStep == .photo)
    #expect(vm.isShowingTouchup == false)
}

@Test @MainActor func addItemOnTouchupDoneUpdatesProcessedImage() async {
    let mockImage = MockImageService()
    let original = makeProcessedImage(maskedData: Data([0x01]))
    mockImage.updateMaskedResult = makeProcessedImage(maskedData: Data([0x02]))

    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.processedImage = original
    vm.isShowingTouchup = true

    await vm.onTouchupDone(makePixelImage(color: .systemRed))

    #expect(mockImage.updateMaskedCallCount == 1)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.currentStep == .details)
    #expect(vm.processedImage?.maskedData == Data([0x02]))
}

@Test @MainActor func addItemOnTouchupDoneWithoutProcessedImageStillAdvances() async {
    let mockImage = MockImageService()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingTouchup = true

    await vm.onTouchupDone(makePixelImage())

    // No processed image → nothing to update, but flow still proceeds.
    #expect(mockImage.updateMaskedCallCount == 0)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.currentStep == .details)
}

@Test @MainActor func addItemOnTouchupSmartRecropReprocessesImage() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(maskedData: Data([0x42]))

    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.selectedImage = makePixelImage()

    await vm.onTouchupSmartRecrop()

    #expect(mockImage.processImageCallCount == 1)
    #expect(vm.processedImage?.maskedData == Data([0x42]))
    #expect(vm.isProcessing == false)
}

@Test @MainActor func addItemOnTouchupSmartRecropNoOpWithoutSelectedImage() async {
    let mockImage = MockImageService()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )

    await vm.onTouchupSmartRecrop()

    #expect(mockImage.processImageCallCount == 0)
    #expect(vm.isProcessing == false)
}

@Test @MainActor func addItemOnTouchupCancelledClosesAndAdvances() {
    let vm = AddItemViewModel()
    vm.isShowingTouchup = true

    vm.onTouchupCancelled()

    #expect(vm.isShowingTouchup == false)
    #expect(vm.currentStep == .details)
}

@Test @MainActor func addItemResetClearsPhase2State() {
    let vm = AddItemViewModel()
    vm.captureMethod = .camera
    vm.isShowingCamera = true
    vm.isShowingTouchup = true
    vm.isShowingTutorial = true

    vm.reset()

    #expect(vm.captureMethod == .library)
    #expect(vm.isShowingCamera == false)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.isShowingTutorial == false)
}

// MARK: - Phase 3: auto-cropped badge + tap-to-select flow

@Test @MainActor func addItemOnCameraPhotoSetsAutoCroppedWhenSam2AutoUsed() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(
        maskedData: Data([0xAB]),
        extractionMethod: .sam2Auto
    )
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true

    await vm.onCameraPhotoCaptured(makePixelImage())

    #expect(vm.isAutoCropped == true)
    #expect(vm.isShowingTouchup == true)
}

@Test @MainActor func addItemOnCameraPhotoClearsAutoCroppedWhenVisionUsed() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(
        maskedData: Data([0xAB]),
        extractionMethod: .vision
    )
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isAutoCropped = true // simulate stale badge from an earlier capture
    vm.isShowingCamera = true

    await vm.onCameraPhotoCaptured(makePixelImage())

    #expect(vm.isAutoCropped == false)
}

@Test @MainActor func addItemOnTroubleCroppingSwitchesToTapToSelect() {
    let vm = AddItemViewModel()
    vm.isShowingTouchup = true

    vm.onTroubleCropping()

    #expect(vm.isShowingTouchup == false)
    #expect(vm.isShowingTapToSelect == true)
}

@Test @MainActor func addItemOnTapToSelectCancelledReturnsToTouchup() {
    let vm = AddItemViewModel()
    vm.isShowingTapToSelect = true

    vm.onTapToSelectCancelled()

    #expect(vm.isShowingTapToSelect == false)
    #expect(vm.isShowingTouchup == true)
}

@Test @MainActor func addItemOnTapToSelectDoneClearsAutoCroppedAndReopensTouchup() async {
    let mockImage = MockImageService()
    mockImage.updateMaskedResult = makeProcessedImage(
        maskedData: Data([0x03]),
        extractionMethod: .sam2Manual
    )
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.processedImage = makeProcessedImage(
        maskedData: Data([0x01]),
        extractionMethod: .sam2Auto
    )
    vm.isAutoCropped = true
    vm.isShowingTapToSelect = true

    let result = ExtractionResult(
        originalImage: makePixelImage(),
        maskedImage: makePixelImage(color: .systemGreen),
        mask: nil,
        confidence: .medium,
        method: .sam2Manual
    )
    await vm.onTapToSelectDone(result)

    #expect(vm.isShowingTapToSelect == false)
    #expect(vm.isAutoCropped == false)
    #expect(vm.isShowingTouchup == true)
    #expect(vm.processedImage?.maskedData == Data([0x03]))
    #expect(mockImage.updateMaskedCallCount == 1)
}

@Test @MainActor func addItemResetClearsPhase3State() {
    let vm = AddItemViewModel()
    vm.isShowingTapToSelect = true
    vm.isAutoCropped = true

    vm.reset()

    #expect(vm.isShowingTapToSelect == false)
    #expect(vm.isAutoCropped == false)
}
