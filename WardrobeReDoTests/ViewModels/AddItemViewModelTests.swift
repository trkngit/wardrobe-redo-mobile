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

@Test @MainActor func addItemOnTapToSelectRequestTouchupOpensBrushEditor() {
    let vm = AddItemViewModel()
    vm.isShowingTapToSelect = true

    vm.onTapToSelectRequestTouchup()

    // Forward-direction counterpart to onTroubleCropping — the user
    // pivots from tap-to-select into the brush editor for pixel-level
    // refinement, then MaskTouchupView's Done callback rejoins the
    // main flow at .details.
    #expect(vm.isShowingTapToSelect == false)
    #expect(vm.isShowingTouchup == true)
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

@Test @MainActor func addItemCancelProcessingShowsCancellationToast() {
    let vm = AddItemViewModel()
    vm.isProcessing = true
    vm.currentStep = .analysis

    vm.cancelProcessing()

    // The toast flips on synchronously so the AddItemView overlay
    // animates the pill in at the same moment the analyzing popup
    // animates out — matched timing prevents a "did the cancel
    // register?" gap. Auto-dismiss after ~1.8s isn't asserted here
    // (would slow the suite); covered manually on the device walk.
    #expect(vm.cancellationToastVisible == true)
}

@Test @MainActor func addItemResetClearsCancellationToast() {
    let vm = AddItemViewModel()
    vm.cancellationToastVisible = true

    vm.reset()

    // Sheet teardown drops the pill — the toast belongs to the live
    // AddItem flow, no point showing it after the user has closed
    // the sheet entirely.
    #expect(vm.cancellationToastVisible == false)
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

// MARK: - Phase 5: multi-garment multi-pick (feature-flagged)

/// `.serialized` — these tests flip `FeatureFlags.isMultiGarmentEnabled`,
/// which is UserDefaults-backed global mutable state. Swift Testing runs
/// tests in parallel by default; without serialization, one test's
/// `isMultiGarmentEnabled = true` races with another's `resetAll()` and
/// the flag-gated assertions flake. Mirrors the pattern already in
/// `ImageServiceProposalsTests`.
@MainActor
@Suite(.serialized)
struct AddItemMultiGarmentTests {

    /// Build a `ProcessedImage` carrying `count` distinct proposals.
    /// Scores are descending (0.9, 0.85, 0.8, …) so the queue-ordering
    /// tests can assert strict ordering. Bounding-box areas increase
    /// with index so the render-order tests (if any) have meaningful
    /// input too.
    private func makeProcessedImageWithProposals(_ count: Int) -> ProcessedImage {
        let props = (0..<count).map { i in
            MaskProposalFixture.make(
                boundingBox: CGRect(
                    x: 0.1, y: 0.1,
                    width: 0.3 + Double(i) * 0.05,
                    height: 0.3
                ),
                detectionScore: Float(0.9 - Double(i) * 0.05)
            )
        }
        return ProcessedImage(
            originalData: Data([0xFF]),
            thumbnailData: Data([0xFF]),
            maskedData: Data([0xAB]),
            extractionConfidence: .high,
            extractionMethod: .multiGarmentRFDETR,
            dominantColors: [],
            proposals: props
        )
    }

    private func makeProcessedImageWithoutProposals() -> ProcessedImage {
        ProcessedImage(
            originalData: Data([0xFF]),
            thumbnailData: Data([0xFF]),
            maskedData: Data([0xAB]),
            extractionConfidence: .high,
            extractionMethod: .vision,
            dominantColors: []
        )
    }

    private func makePixelImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: - Routing

    @Test func routesToMultiPickWhenFlagOnAndTwoOrMoreProposals() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(3)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true

        await vm.onCameraPhotoCaptured(makePixelImage())

        #expect(vm.isShowingMultiPick == true)
        #expect(vm.isShowingTapToSelect == false)
        #expect(vm.proposals?.count == 3)
        #expect(vm.selectedProposalIDs.count == 3, "all proposals start selected")
    }

    @Test func addItemSingleProposalFallsThroughToExistingFlow() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(1)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true

        await vm.onCameraPhotoCaptured(makePixelImage())

        #expect(vm.isShowingMultiPick == false)
        #expect(vm.isShowingTapToSelect == true)
    }

    @Test func addItemNoProposalsFallsThroughToExistingFlow() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithoutProposals()
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true

        await vm.onCameraPhotoCaptured(makePixelImage())

        #expect(vm.isShowingMultiPick == false)
        #expect(vm.isShowingTapToSelect == true)
    }

    @Test func addItemFeatureFlagOffSkipsMultiPickEntirely() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = false
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        // Deliberately stuff proposals into the ProcessedImage — belt-
        // and-suspenders check that the VM's routing gate (not just
        // ImageService) respects the flag.
        mockImage.processImageResult = makeProcessedImageWithProposals(5)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true

        await vm.onCameraPhotoCaptured(makePixelImage())

        #expect(vm.isShowingMultiPick == false)
        #expect(vm.isShowingTapToSelect == true, "flag off → single-item flow even if proposals attached")
        #expect(vm.proposals == nil, "routing gate drops proposals when flag is off")
    }

    @Test func addItemUseFullPhotoEscapeRoutesToSingleItemFlow() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(3)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())
        #expect(vm.isShowingMultiPick == true) // precondition

        vm.onMultiPickUseFullPhoto()

        #expect(vm.isShowingMultiPick == false)
        #expect(vm.isShowingTapToSelect == true)
        #expect(vm.proposals == nil)
        #expect(vm.pendingProposalQueue.isEmpty)
    }

    // MARK: - Queue progression

    @Test func confirmQueuesSelectedProposalsScoreDescending() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(3)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())

        vm.onMultiPickConfirmed()

        #expect(vm.currentProposal != nil, "first proposal popped into details")
        #expect(vm.pendingProposalQueue.count == 2, "remaining 2 still queued")
        #expect(vm.currentStep == .details)
        #expect(vm.isShowingMultiPick == false)
        // Highest-scored proposal is detailed first.
        let sortedScores = (vm.proposals ?? []).sorted { $0.detectionScore > $1.detectionScore }
        #expect(vm.currentProposal?.id == sortedScores.first?.id)
    }

    @Test func addItemMultiPickQueueProgressesThroughDetails() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(3)
        let mockRepo = MockWardrobeRepository()
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: mockRepo
        )
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())
        vm.onMultiPickConfirmed()

        let firstProposalId = vm.currentProposal?.id

        // Save #1 → second proposal becomes current.
        await vm.save(userId: UUID())
        #expect(mockRepo.insertItemCallCount == 1)
        #expect(vm.currentProposal != nil)
        #expect(vm.currentProposal?.id != firstProposalId)
        #expect(vm.pendingProposalQueue.count == 1)
        #expect(vm.savedItemsFromSource == 1)
        #expect(vm.didSave == false, "batch in progress shouldn't dismiss")

        let secondProposalId = vm.currentProposal?.id

        // Save #2 → third proposal becomes current.
        await vm.save(userId: UUID())
        #expect(mockRepo.insertItemCallCount == 2)
        #expect(vm.currentProposal != nil)
        #expect(vm.currentProposal?.id != firstProposalId)
        #expect(vm.currentProposal?.id != secondProposalId)
        #expect(vm.pendingProposalQueue.isEmpty)
        #expect(vm.savedItemsFromSource == 2)

        // Save #3 → queue empty, batch done, sheet dismisses.
        await vm.save(userId: UUID())
        #expect(mockRepo.insertItemCallCount == 3)
        #expect(vm.currentProposal == nil)
        #expect(vm.pendingProposalQueue.isEmpty)
        #expect(vm.savedItemsFromSource == 3)
        #expect(vm.didSave == true, "batch complete → sheet dismisses")
    }

    @Test func addItemMultiPickAllowsSkip() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(3)
        let mockRepo = MockWardrobeRepository()
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: mockRepo
        )
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())
        vm.onMultiPickConfirmed()
        let firstProposalId = vm.currentProposal?.id

        vm.onSkipCurrentProposal()

        #expect(mockRepo.insertItemCallCount == 0, "skip doesn't save")
        #expect(vm.currentProposal != nil, "second proposal should now be current")
        #expect(vm.currentProposal?.id != firstProposalId)
        #expect(vm.pendingProposalQueue.count == 1)
        #expect(vm.savedItemsFromSource == 0)
    }

    @Test func skippingAllProposalsFallsBackToPhotoStep() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(2)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())
        vm.onMultiPickConfirmed()

        vm.onSkipCurrentProposal() // skip #1 (queue still has #2)
        vm.onSkipCurrentProposal() // skip #2 (queue now empty)

        #expect(vm.currentProposal == nil)
        #expect(vm.savedItemsFromSource == 0)
        #expect(vm.didSave == false, "skipping everything shouldn't dismiss; user gets photo step")
        #expect(vm.currentStep == .photo)
    }

    @Test func cancelMultiPickReturnsToPhotoStep() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        mockImage.processImageResult = makeProcessedImageWithProposals(2)
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())

        vm.onMultiPickCancelled()

        #expect(vm.isShowingMultiPick == false)
        #expect(vm.currentStep == .photo)
        #expect(vm.proposals == nil)
    }

    @Test func addItemResetWipesPhase5State() {
        let vm = AddItemViewModel()
        vm.proposals = [MaskProposalFixture.make()]
        vm.selectedProposalIDs = [UUID()]
        vm.pendingProposalQueue = [MaskProposalFixture.make()]
        vm.currentProposal = MaskProposalFixture.make()
        vm.isShowingMultiPick = true

        vm.reset()

        #expect(vm.proposals == nil)
        #expect(vm.selectedProposalIDs.isEmpty)
        #expect(vm.pendingProposalQueue.isEmpty)
        #expect(vm.currentProposal == nil)
        #expect(vm.isShowingMultiPick == false)
    }

    @Test func stampFreshCaptureClearsProposalStateOnNewPhoto() async {
        // User took one multi-garment photo, now takes a second that
        // happens to return no proposals — the first capture's queue /
        // selection shouldn't leak into the second capture.
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isMultiGarmentEnabled = true
        defer { FeatureFlags.resetAll() }

        let mockImage = MockImageService()
        let vm = AddItemViewModel(
            imageService: mockImage,
            wardrobeRepository: MockWardrobeRepository()
        )

        // First capture → 3 proposals.
        mockImage.processImageResult = makeProcessedImageWithProposals(3)
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())
        #expect(vm.proposals?.count == 3)

        // Second capture → no proposals. Stale state must be cleared.
        mockImage.processImageResult = makeProcessedImageWithoutProposals()
        vm.isShowingCamera = true
        await vm.onCameraPhotoCaptured(makePixelImage())

        #expect(vm.proposals == nil)
        #expect(vm.selectedProposalIDs.isEmpty)
        #expect(vm.isShowingMultiPick == false)
        #expect(vm.isShowingTapToSelect == true)
    }
}
