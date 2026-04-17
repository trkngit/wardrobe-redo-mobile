import Foundation
import Observation
import os
import UIKit
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class AddItemViewModel {
    // MARK: - State

    enum Step: Int, CaseIterable {
        case photo = 0
        case analysis = 1
        case details = 2
        case saving = 3
    }

    /// How the user got to this screen's photo. Drives whether we show
    /// the mask touch-up sheet after extraction — library pickers don't
    /// get one in Phase 2 because they typically already have a clean
    /// background, while camera captures are offered touch-up as a
    /// fallback for cluttered scenes.
    enum CaptureMethod: String, Sendable, Equatable {
        case library
        case camera
    }

    var currentStep: Step = .photo
    var selectedPhoto: PhotosPickerItem?
    var selectedImage: UIImage?
    var processedImage: ProcessedImage?

    // Item metadata
    var category: ClothingCategory = .top
    var subcategory: ClothingSubcategory = .tshirt
    var texture: TextureType?
    var fitAttribute: FitAttribute?
    var selectedSeasons: Set<Season> = Set(Season.allCases)
    var selectedOccasions: Set<Occasion> = [.casual]

    // UI state
    var isProcessing = false
    var isSaving = false
    var errorMessage: String?
    var didSave = false

    // Phase 2: camera flow
    var captureMethod: CaptureMethod = .library
    var isShowingCamera = false
    var isShowingTouchup = false
    var isShowingTutorial = false

    // Phase 3: SAM2 manual override
    var isShowingTapToSelect = false
    /// Set when Vision confidence was low and we fell back to the
    /// automatic SAM2 mask. Drives the "Auto-cropped" badge in
    /// `MaskTouchupView` so the user knows to sanity-check.
    var isAutoCropped = false

    // MARK: - Dependencies

    private let imageService: any ImageServiceProtocol
    private let wardrobeRepository: any WardrobeRepositoryProtocol
    /// Exposed so the Phase 3 TapToSelectView can call back into the
    /// same extractor instance as the rest of the pipeline (no duplicate
    /// model loads, no cold-starts per tap).
    let clothingExtractor: any ClothingExtracting
    private let logger = Logger(subsystem: "com.wardroberedo", category: "AddItem")

    init(
        imageService: any ImageServiceProtocol = ImageService(),
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository(),
        clothingExtractor: any ClothingExtracting = ClothingExtractionService()
    ) {
        self.imageService = imageService
        self.wardrobeRepository = wardrobeRepository
        self.clothingExtractor = clothingExtractor
    }

    // MARK: - Computed

    var extractedColors: [ColorProfile] {
        processedImage?.dominantColors.map { $0.toColorProfile() } ?? []
    }

    var availableSubcategories: [ClothingSubcategory] {
        ClothingSubcategory.subcategories(for: category)
    }

    var canSave: Bool {
        processedImage != nil && !isSaving
    }

    // MARK: - Actions

    func onPhotoSelected() async {
        guard let item = selectedPhoto else { return }

        captureMethod = .library
        isProcessing = true
        errorMessage = nil
        currentStep = .analysis

        guard let image = await imageService.loadImage(from: item) else {
            errorMessage = "Couldn't load that image. Try another one."
            currentStep = .photo
            isProcessing = false
            return
        }

        selectedImage = image

        guard let processed = await imageService.processImage(image) else {
            errorMessage = "Couldn't process that image. Try another one."
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        isProcessing = false
        currentStep = .details
    }

    func onCategoryChanged() {
        let subs = availableSubcategories
        if !subs.contains(subcategory), let first = subs.first {
            subcategory = first
        }
    }

    // MARK: - Camera flow

    /// Entry point for "Take Photo" on the source picker. Shows the
    /// first-run tutorial the first time through, then opens the camera
    /// fullscreen. All tutorial gating is driven by `FirstRunTutorialView`.
    func beginCameraCapture() {
        captureMethod = .camera
        errorMessage = nil
        if FirstRunTutorialView.hasBeenSeen {
            isShowingCamera = true
        } else {
            isShowingTutorial = true
        }
    }

    /// Called when the first-run tutorial is dismissed. Proceeds into
    /// the camera flow if the user was about to take a photo.
    func onTutorialDismissed() {
        isShowingTutorial = false
        if captureMethod == .camera {
            isShowingCamera = true
        }
    }

    /// Called from `CameraCaptureView.onPhotoCaptured` with the raw
    /// capture. Runs the full extraction pipeline, shows the touch-up
    /// sheet when a mask was produced (so the user can refine it), or
    /// jumps straight to details when extraction fell through.
    func onCameraPhotoCaptured(_ image: UIImage) async {
        isShowingCamera = false
        selectedImage = image
        isProcessing = true
        errorMessage = nil
        currentStep = .analysis

        guard let processed = await imageService.processImage(image) else {
            errorMessage = "Couldn't process that photo. Try again."
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        isAutoCropped = (processed.extractionMethod == .sam2Auto)
        isProcessing = false

        if processed.maskedData != nil {
            // Show touchup so the user can confirm or refine the mask.
            isShowingTouchup = true
        } else {
            currentStep = .details
        }
    }

    /// User cancelled out of the camera view without capturing anything.
    /// Reset the capture method so the next interaction is fresh.
    func onCameraCancelled() {
        isShowingCamera = false
        captureMethod = .library
    }

    /// User finished in `MaskTouchupView` and wants to keep the edited
    /// mask. Re-runs color extraction on the edited image so the saved
    /// palette matches the new alpha.
    func onTouchupDone(_ editedMask: UIImage) async {
        isShowingTouchup = false
        guard let processed = processedImage else {
            currentStep = .details
            return
        }
        if let updated = await imageService.updateMasked(processed: processed, editedMask: editedMask) {
            processedImage = updated
        }
        currentStep = .details
    }

    /// User tapped "Smart re-crop" in the touch-up sheet — re-run the
    /// full extraction pipeline on the captured image. The pipeline
    /// itself chains Vision → SAM2-auto internally, so this re-runs
    /// both when appropriate.
    func onTouchupSmartRecrop() async {
        guard let image = selectedImage else { return }
        isProcessing = true
        if let processed = await imageService.processImage(image) {
            processedImage = processed
            isAutoCropped = (processed.extractionMethod == .sam2Auto)
        }
        isProcessing = false
    }

    /// User dismissed the touch-up sheet without changes. Keep the
    /// extraction result as-is and continue to details.
    func onTouchupCancelled() {
        isShowingTouchup = false
        currentStep = .details
    }

    // MARK: - Phase 3 manual tap-to-select

    /// User tapped "Trouble cropping?" inside `MaskTouchupView`. Hide the
    /// touchup sheet and push the `TapToSelectView` flow.
    func onTroubleCropping() {
        isShowingTouchup = false
        isShowingTapToSelect = true
    }

    /// User finished `TapToSelectView` and wants to use the SAM2-manual
    /// result. Rebuild `ProcessedImage` from the new mask so the saved
    /// palette matches, then re-enter the touch-up sheet so the user can
    /// still brush refinements on top.
    func onTapToSelectDone(_ result: ExtractionResult) async {
        isShowingTapToSelect = false
        // Re-encode the new mask into storage-ready PNG + re-run color
        // extraction by funnelling through `imageService.updateMasked`.
        if let current = processedImage {
            if let updated = await imageService.updateMasked(
                processed: current,
                editedMask: result.maskedImage
            ) {
                processedImage = updated
            }
        }
        // Manual tap-to-select is the highest-trust path — clear the
        // auto-cropped badge and let the user finish in touchup.
        isAutoCropped = false
        if processedImage?.maskedData != nil {
            isShowingTouchup = true
        } else {
            currentStep = .details
        }
    }

    /// User backed out of `TapToSelectView` — go back to the touch-up
    /// sheet with the pre-existing mask intact.
    func onTapToSelectCancelled() {
        isShowingTapToSelect = false
        isShowingTouchup = true
    }

    func save(userId: UUID) async {
        guard let processed = processedImage else { return }

        isSaving = true
        currentStep = .saving
        errorMessage = nil
        defer { isSaving = false }

        let itemId = UUID()
        let colors = extractedColors
        let cat = category.rawValue
        let subcat = subcategory.rawValue
        let tex = texture?.rawValue
        let fit = fitAttribute?.rawValue
        let seasons = Array(selectedSeasons).map(\.rawValue)
        let occasions = Array(selectedOccasions).map(\.rawValue)

        logger.info("save: starting upload for itemId=\(itemId)")

        let extractionConfidenceRaw = processed.extractionConfidence?.rawValue

        // Race the entire save operation against a 45-second timeout
        let success: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [imageService, wardrobeRepository, logger] in
                var uploadedPaths: (imagePath: String, thumbnailPath: String, maskedImagePath: String?)?

                do {
                    let paths = try await imageService.upload(
                        processed: processed,
                        userId: userId,
                        itemId: itemId
                    )
                    uploadedPaths = paths
                    logger.info("save: upload complete, inserting item")

                    let newItem = NewWardrobeItem(
                        userId: userId,
                        imagePath: paths.imagePath,
                        thumbnailPath: paths.thumbnailPath,
                        maskedImagePath: paths.maskedImagePath,
                        extractionConfidence: extractionConfidenceRaw,
                        // Source-photo grouping (migration 00008) is
                        // populated by the "Save & add another garment"
                        // loop in Commit 5. For now every save is a
                        // single-item capture and the columns stay nil,
                        // matching legacy behavior.
                        sourcePhotoId: nil,
                        sourcePhotoPath: nil,
                        category: cat,
                        subcategory: subcat,
                        dominantColors: colors,
                        texture: tex,
                        fitAttribute: fit,
                        seasons: seasons,
                        occasions: occasions
                    )

                    _ = try await wardrobeRepository.insertItem(newItem)
                    logger.info("save: insert complete")
                    return true
                } catch {
                    logger.error("save: failed — \(error.localizedDescription)")

                    // Cleanup: if upload succeeded but DB insert failed,
                    // delete orphaned images to prevent storage leaks.
                    // Include the masked file when it was actually uploaded.
                    if let paths = uploadedPaths {
                        logger.info("save: cleaning up orphaned images")
                        try? await imageService.deleteImages(
                            imagePath: paths.imagePath,
                            thumbnailPath: paths.thumbnailPath,
                            maskedImagePath: paths.maskedImagePath
                        )
                    }
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return false
            }

            let result = await group.next()!
            group.cancelAll()
            return result
        }

        if success {
            didSave = true
        } else {
            errorMessage = "Failed to save item. Check your connection and try again."
            currentStep = .details
        }
    }

    func reset() {
        currentStep = .photo
        selectedPhoto = nil
        selectedImage = nil
        processedImage = nil
        category = .top
        subcategory = .tshirt
        texture = nil
        fitAttribute = nil
        selectedSeasons = Set(Season.allCases)
        selectedOccasions = [.casual]
        isProcessing = false
        isSaving = false
        errorMessage = nil
        didSave = false
        captureMethod = .library
        isShowingCamera = false
        isShowingTouchup = false
        isShowingTutorial = false
        isShowingTapToSelect = false
        isAutoCropped = false
    }
}
