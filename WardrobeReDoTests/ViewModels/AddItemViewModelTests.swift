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

@Test @MainActor func addItemOnCameraPhotoCapturedWithMaskOpensTapToSelect() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(maskedData: Data([0xAB]))
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true
    vm.currentStep = .photo

    await vm.onCameraPhotoCaptured(makePixelImage())

    // After the tap-to-select-first redesign, every successful capture
    // routes into TapToSelectView pre-populated with the auto mask —
    // touchup is now reachable only via the explicit "Refine with brush"
    // detour. See `unified-mapping-honey.md` Part 2.
    #expect(vm.isShowingCamera == false)
    #expect(vm.isShowingTapToSelect == true)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.processedImage != nil)
    #expect(vm.processedImage?.maskedData != nil)
    #expect(mockImage.processImageCallCount == 1)
}

@Test @MainActor func addItemOnCameraPhotoCapturedWithoutMaskAlsoOpensTapToSelect() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(maskedData: nil)
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true

    await vm.onCameraPhotoCaptured(makePixelImage())

    // Tap-to-select opens regardless of mask quality. With no upstream
    // mask, the user gets an empty canvas to tap their way through —
    // strictly better than the old "skip straight to details with no
    // crop" path.
    #expect(vm.isShowingCamera == false)
    #expect(vm.isShowingTapToSelect == true)
    #expect(vm.isShowingTouchup == false)
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
    #expect(vm.isShowingTapToSelect == false)
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

    // The badge state still tracks the upstream method even though it's
    // now consumed inside TapToSelectView (the "Auto-detected" hint)
    // rather than MaskTouchupView. Tap-to-select is the new
    // post-processing surface.
    #expect(vm.isAutoCropped == true)
    #expect(vm.isShowingTapToSelect == true)
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

@Test @MainActor func addItemOnTapToSelectCancelledRoutesToDetails() {
    let vm = AddItemViewModel()
    vm.isShowingTapToSelect = true

    vm.onTapToSelectCancelled()

    // The "Back" affordance on tap-to-select is now a flow exit, not a
    // detour to touchup. Drops the user at `.details` so they can either
    // save what they have or scrap and start over from `.photo`.
    #expect(vm.isShowingTapToSelect == false)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.currentStep == .details)
}

@Test @MainActor func addItemOnTapToSelectDoneRoutesToDetails() async {
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

    // "Use this crop" is now the primary flow forward — straight to the
    // metadata-entry step. Touchup is no longer auto-opened; it's only
    // reachable via the explicit "Refine with brush" detour. The
    // auto-cropped badge is cleared because the user explicitly committed
    // to the (possibly-refined) mask.
    #expect(vm.isShowingTapToSelect == false)
    #expect(vm.isAutoCropped == false)
    #expect(vm.isShowingTouchup == false)
    #expect(vm.currentStep == .details)
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

// MARK: - Phase 4: Save & add another garment (per-capture loop)

/// Minimal `SAM2Session` stub. Tests set this on the ViewModel to
/// unlock the `onSaveAndAddAnother(userId:)` path; the stub's
/// `segment(points:)` is never called because the loop-back writes
/// go through `wardrobeRepository.insertItem`, not SAM2.
private final class StubSAM2Session: SAM2Session, @unchecked Sendable {
    func segment(points: [SAM2TapPoint]) async -> SAM2Result? { nil }
}

@Test @MainActor func addItemOnCameraPhotoCapturedStampsSourcePhotoId() async {
    let mockImage = MockImageService()
    mockImage.processImageResult = makeProcessedImage(maskedData: Data([0xAB]))
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: MockWardrobeRepository()
    )
    vm.isShowingCamera = true

    #expect(vm.sourcePhotoId == nil) // precondition

    await vm.onCameraPhotoCaptured(makePixelImage())

    #expect(vm.sourcePhotoId != nil)
    #expect(vm.savedItemsFromSource == 0)
    #expect(vm.sourcePhotoPath == nil) // not set until first successful save
}

@Test @MainActor func addItemSavePassesSourcePhotoIdThroughToInsert() async {
    let mockImage = MockImageService()
    let mockRepo = MockWardrobeRepository()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: mockRepo
    )
    let expectedId = UUID()
    vm.processedImage = makeProcessedImage(maskedData: Data([0xAB]))
    vm.sourcePhotoId = expectedId

    await vm.save(userId: UUID())

    #expect(mockRepo.insertItemCallCount == 1)
    #expect(mockRepo.lastInsertedItem?.sourcePhotoId == expectedId)
    // First save of a capture: ImageService returns a fresh path →
    // ViewModel caches it for garments 2..N.
    #expect(vm.sourcePhotoPath == mockImage.uploadSourcePhotoPath)
    #expect(vm.savedItemsFromSource == 1)
}

@Test @MainActor func addItemSaveAndAddAnotherNoOpWithoutSession() async {
    let mockImage = MockImageService()
    let mockRepo = MockWardrobeRepository()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: mockRepo
    )
    vm.selectedImage = makePixelImage()
    vm.processedImage = makeProcessedImage(maskedData: Data([0xAB]))
    vm.sourcePhotoId = UUID()
    // No sam2Session set

    await vm.onSaveAndAddAnother(userId: UUID())

    // Session guard short-circuits before the save runs
    #expect(mockImage.uploadCallCount == 0)
    #expect(mockRepo.insertItemCallCount == 0)
    #expect(vm.wantsAnotherGarment == false)
    #expect(vm.isShowingTapToSelect == false)
}

@Test @MainActor func addItemSaveAndAddAnotherLoopsBackIntoTapToSelect() async {
    let mockImage = MockImageService()
    let mockRepo = MockWardrobeRepository()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: mockRepo
    )
    vm.selectedImage = makePixelImage()
    vm.processedImage = makeProcessedImage(maskedData: Data([0xAB]))
    vm.sourcePhotoId = UUID()
    vm.sam2Session = StubSAM2Session()
    // Pretend the user picked a custom category — the loop reset
    // should knock it back to the default.
    vm.category = .shoe
    vm.subcategory = .sneakers

    await vm.onSaveAndAddAnother(userId: UUID())

    #expect(mockRepo.insertItemCallCount == 1)
    #expect(vm.savedItemsFromSource == 1)
    #expect(vm.didSave == false, "loop path must not dismiss the sheet")
    #expect(vm.isShowingTapToSelect == true)
    #expect(vm.wantsAnotherGarment == false, "flag should reset after save")
    // Captured-image state preserved
    #expect(vm.selectedImage != nil)
    #expect(vm.sourcePhotoId != nil)
    #expect(vm.sam2Session != nil)
    // Item-specific metadata rolled back to defaults
    #expect(vm.category == .top)
    #expect(vm.subcategory == .tshirt)
}

@Test @MainActor func addItemSaveAndAddAnotherReusesSourcePhotoPath() async {
    let mockImage = MockImageService()
    mockImage.uploadSourcePhotoPath = "users/abc/source/cap-xyz/original.jpg"
    let mockRepo = MockWardrobeRepository()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: mockRepo
    )
    vm.selectedImage = makePixelImage()
    vm.processedImage = makeProcessedImage(maskedData: Data([0xAB]))
    vm.sourcePhotoId = UUID()
    vm.sam2Session = StubSAM2Session()

    // First save: ImageService sees no existing path, uploads the
    // source photo, and returns the new path.
    await vm.onSaveAndAddAnother(userId: UUID())
    #expect(mockImage.uploadCallCount == 1)
    // Inner nil check via ?? fallback: outer nil (never called) gets a
    // sentinel string so the assertion fails loudly; outer .some(nil)
    // collapses to nil and passes; outer .some("x") fails.
    #expect((mockImage.lastUploadExistingSourcePhotoPath ?? "NEVER-CALLED") == nil)
    #expect(vm.sourcePhotoPath == "users/abc/source/cap-xyz/original.jpg")

    // Simulate garment 2: user just finished tap-to-select, mask was
    // swapped into processedImage, details filled in → tap "Save &
    // add another" again.
    vm.processedImage = makeProcessedImage(maskedData: Data([0xCD]))

    await vm.onSaveAndAddAnother(userId: UUID())

    #expect(mockImage.uploadCallCount == 2)
    #expect(
        (mockImage.lastUploadExistingSourcePhotoPath ?? "NEVER-CALLED")
            == "users/abc/source/cap-xyz/original.jpg",
        "second save must pass the cached source path so ImageService skips re-upload"
    )
    #expect(vm.savedItemsFromSource == 2)
    #expect(vm.isShowingTapToSelect == true)
}

@Test @MainActor func addItemSaveFinalGarmentDismissesInsteadOfLooping() async {
    let mockImage = MockImageService()
    let mockRepo = MockWardrobeRepository()
    let vm = AddItemViewModel(
        imageService: mockImage,
        wardrobeRepository: mockRepo
    )
    vm.selectedImage = makePixelImage()
    vm.processedImage = makeProcessedImage(maskedData: Data([0xAB]))
    vm.sourcePhotoId = UUID()
    vm.sam2Session = StubSAM2Session()
    // Simulate one prior "Save & add another" already happened — user
    // is on garment 2 and hits the primary "Save" button (not the
    // loop-back variant).
    vm.savedItemsFromSource = 1
    vm.sourcePhotoPath = "users/abc/source/cap/original.jpg"

    await vm.save(userId: UUID())

    #expect(mockRepo.insertItemCallCount == 1)
    #expect(vm.savedItemsFromSource == 2)
    #expect(vm.didSave == true, "regular Save must still end the capture flow")
    #expect(vm.isShowingTapToSelect == false)
}

@Test @MainActor func addItemCancelProcessingResetsToPhotoStep() {
    let vm = AddItemViewModel()
    // Simulate the state the ViewModel is in mid-processing: the
    // analyzing-popup overlay drives off `isProcessing`, and the
    // current step is `.analysis` while extraction runs.
    vm.isProcessing = true
    vm.currentStep = .analysis
    vm.selectedImage = makePixelImage()
    vm.errorMessage = "stale error from a previous attempt"

    vm.cancelProcessing()

    #expect(vm.isProcessing == false)
    #expect(vm.currentStep == .photo)
    #expect(vm.selectedImage == nil, "selected image should clear so the next pick is fresh")
    #expect(vm.errorMessage == nil, "stale errors should clear on cancel")
}

@Test @MainActor func addItemResetWipesPhase4State() {
    let vm = AddItemViewModel()
    vm.sourcePhotoId = UUID()
    vm.sourcePhotoPath = "users/test/source/cap/original.jpg"
    vm.sam2Session = StubSAM2Session()
    vm.savedItemsFromSource = 3
    vm.wantsAnotherGarment = true

    vm.reset()

    #expect(vm.sourcePhotoId == nil)
    #expect(vm.sourcePhotoPath == nil)
    #expect(vm.sam2Session == nil)
    #expect(vm.savedItemsFromSource == 0)
    #expect(vm.wantsAnotherGarment == false)
}
