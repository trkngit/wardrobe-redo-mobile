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

    // Phase 4: "Save & add another garment" per-capture loop

    /// Stable identity for the current capture. Every garment row
    /// extracted from the same source photo shares this UUID (populated
    /// into `wardrobe_items.source_photo_id` via migration 00008).
    /// Stamped fresh on every photo selection / camera capture; cleared
    /// by `reset()`. Nil on legacy / single-item flows that never
    /// enter the multi-garment loop.
    var sourcePhotoId: UUID?

    /// Storage path to the unmasked source JPEG at
    /// `{userId}/source/{sourcePhotoId}/original.jpg`. Populated by
    /// `ImageService.upload(...)` on the FIRST save of a multi-garment
    /// loop and echoed back on garments 2..N so the original isn't
    /// re-uploaded. Nil iff `sourcePhotoId` is nil.
    var sourcePhotoPath: String?

    /// Reusable SAM2 segmentation session bound to `selectedImage`.
    /// Started in parallel with `processImage(_:)` so the first tap in
    /// `TapToSelectView` doesn't pay the CGImage → 1024×1024 resize
    /// cost on the user-visible path. Nil when SAM2 isn't available
    /// (missing LFS bundle / old iOS) — callers hide the "Save & add
    /// another" button in that case.
    var sam2Session: (any SAM2Session)?

    /// In-flight SAM2 session-load task. Stored on the ViewModel so a
    /// rapid second photo-pick / camera-capture can cancel the prior
    /// load before kicking off another, instead of letting two
    /// concurrent MLModel loads race for ~100 MB of working memory each.
    /// See the "bound heap in capture loop" fix in plan
    /// `unified-mapping-honey.md`.
    private var sessionLoadTask: Task<(any SAM2Session)?, Never>?

    /// Number of wardrobe_item rows saved from the current capture so
    /// far. Zero on every fresh photo selection; increments on each
    /// successful save during the multi-garment loop. Drives the
    /// "Garment N from this photo" badge and tells the UI when it's
    /// safe to show the loop affordances.
    var savedItemsFromSource: Int = 0

    /// Set by `onSaveAndAddAnother(userId:)` immediately before
    /// `save(userId:)` runs. The save-success branch reads this to
    /// decide whether to loop back into tap-to-select or dismiss.
    /// Always cleared on failure so the next tap of the regular Save
    /// button behaves as a normal single-item save.
    var wantsAnotherGarment: Bool = false

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
        stampFreshCapture()

        // Kick off SAM2 session load concurrently with Vision processing.
        // The session isn't consumed until the user reaches tap-to-select
        // (either "Trouble cropping?" or "Save & add another"), so its
        // ~60 ms pixel-buffer resize completes behind the processing
        // wait and the first tap in the user flow fires without a cold
        // start. Cheap (session is non-optional Sendable) but net-win.
        //
        // Cancel any in-flight session load from a prior capture before
        // starting a new one — rapid back-to-back photo selections
        // would otherwise stack two MLModel loads in memory.
        sessionLoadTask?.cancel()
        let sessionTask = Task { [clothingExtractor] in
            await clothingExtractor.makeSession(for: image)
        }
        sessionLoadTask = sessionTask

        guard let processed = await imageService.processImage(image) else {
            sessionTask.cancel()
            sessionLoadTask = nil
            errorMessage = "Couldn't process that image. Try another one."
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        sam2Session = await sessionTask.value
        sessionLoadTask = nil
        // Drop the full-resolution UIImage now that processing is done.
        // The 1200×1200 JPEG inside `processed.originalData` is what
        // gets uploaded to Storage and what TapToSelectView normalizes
        // to image-space `[0,1]` coordinates anyway, so swapping
        // `selectedImage` for the resized version trims ~45 MB of
        // pinned RAM per active capture without changing behaviour.
        if let resized = UIImage(data: processed.originalData) {
            selectedImage = resized
        }
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
        stampFreshCapture()
        isProcessing = true
        errorMessage = nil
        currentStep = .analysis

        // Run the SAM2 session prep alongside extraction — see
        // `onPhotoSelected()` for the rationale, including why we
        // cancel any prior in-flight session load before starting.
        sessionLoadTask?.cancel()
        let sessionTask = Task { [clothingExtractor] in
            await clothingExtractor.makeSession(for: image)
        }
        sessionLoadTask = sessionTask

        guard let processed = await imageService.processImage(image) else {
            sessionTask.cancel()
            sessionLoadTask = nil
            errorMessage = "Couldn't process that photo. Try again."
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        isAutoCropped = (processed.extractionMethod == .sam2Auto)
        sam2Session = await sessionTask.value
        sessionLoadTask = nil
        // Downsample the retained UIImage — see `onPhotoSelected()`
        // for the rationale.
        if let resized = UIImage(data: processed.originalData) {
            selectedImage = resized
        }
        isProcessing = false

        if processed.maskedData != nil {
            // Show touchup so the user can confirm or refine the mask.
            isShowingTouchup = true
        } else {
            currentStep = .details
        }
    }

    /// Reset the per-capture provenance state so the next photo gets
    /// its own `source_photo_id` + a fresh save counter. Called at the
    /// top of every photo-selection / camera-capture lifecycle, BEFORE
    /// any extraction or save. Keeps the multi-garment loop scoped to
    /// one capture at a time.
    private func stampFreshCapture() {
        sourcePhotoId = UUID()
        sourcePhotoPath = nil
        savedItemsFromSource = 0
        wantsAnotherGarment = false
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

        // Hoist capture-level state into locals: the upload Task
        // runs detached from self, so it needs isolated copies of
        // sourcePhotoId / sourcePhotoPath to feed into ImageService.
        let capturedSourcePhotoId = sourcePhotoId
        let existingSourcePath = sourcePhotoPath
        let shouldLoopAfter = wantsAnotherGarment

        logger.info("save: starting upload for itemId=\(itemId) sourcePhotoId=\(capturedSourcePhotoId?.uuidString ?? "nil") savedSoFar=\(self.savedItemsFromSource)")

        let extractionConfidenceRaw = processed.extractionConfidence?.rawValue

        // Race the entire save operation against a 45-second timeout.
        // The tuple carries (success, resolvedSourcePhotoPath) so the
        // main-actor branch below can persist the source path back onto
        // the ViewModel for garments 2..N to reuse.
        let outcome: (success: Bool, sourcePath: String?) = await withTaskGroup(
            of: (Bool, String?).self
        ) { group in
            group.addTask { [imageService, wardrobeRepository, logger] in
                var uploadedPaths: (imagePath: String, thumbnailPath: String, maskedImagePath: String?)?

                do {
                    let paths = try await imageService.upload(
                        processed: processed,
                        userId: userId,
                        itemId: itemId,
                        sourcePhotoId: capturedSourcePhotoId,
                        existingSourcePhotoPath: existingSourcePath
                    )
                    uploadedPaths = (paths.imagePath, paths.thumbnailPath, paths.maskedImagePath)
                    logger.info("save: upload complete, inserting item")

                    let newItem = NewWardrobeItem(
                        userId: userId,
                        imagePath: paths.imagePath,
                        thumbnailPath: paths.thumbnailPath,
                        maskedImagePath: paths.maskedImagePath,
                        extractionConfidence: extractionConfidenceRaw,
                        // `sourcePhotoId` stays stable across every save
                        // in a multi-garment loop; `sourcePhotoPath` is
                        // populated by ImageService on the first save
                        // and echoed back on 2..N. Both are nil on
                        // single-item captures where `stampFreshCapture`
                        // ran but the loop was never entered — matching
                        // the legacy row shape.
                        sourcePhotoId: capturedSourcePhotoId,
                        sourcePhotoPath: paths.sourcePhotoPath,
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
                    return (true, paths.sourcePhotoPath)
                } catch {
                    logger.error("save: failed — \(error.localizedDescription)")

                    // Cleanup: if upload succeeded but DB insert failed,
                    // delete orphaned per-item images to prevent storage
                    // leaks. Intentionally DO NOT remove the source-photo
                    // object — sibling garments in the same capture may
                    // already reference it, and a partial cleanup here
                    // would strand those rows.
                    if let paths = uploadedPaths {
                        logger.info("save: cleaning up orphaned images")
                        try? await imageService.deleteImages(
                            imagePath: paths.imagePath,
                            thumbnailPath: paths.thumbnailPath,
                            maskedImagePath: paths.maskedImagePath
                        )
                    }
                    return (false, nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return (false, nil)
            }

            let first = await group.next() ?? (false, nil)
            group.cancelAll()
            return first
        }

        if outcome.success {
            // Persist the resolved source path back onto the ViewModel
            // so garments 2..N of the same capture reuse it (and
            // ImageService sees it via `existingSourcePhotoPath` →
            // skips the re-upload). Idempotent: on garments 2..N the
            // outcome already carries the pre-existing value.
            if sourcePhotoPath == nil, let persistedPath = outcome.sourcePath {
                sourcePhotoPath = persistedPath
            }
            savedItemsFromSource += 1

            if shouldLoopAfter {
                // "Save & add another garment" path: keep the captured
                // image + session hot, clear only item-specific metadata,
                // and re-enter tap-to-select for the next garment.
                resetKeepingSource()
                isShowingTapToSelect = true
            } else {
                didSave = true
            }
        } else {
            errorMessage = "Failed to save item. Check your connection and try again."
            currentStep = .details
            // Always clear the "add another" flag on failure — the next
            // tap of the regular Save button should behave as a normal
            // single-item save, not silently loop back to tap-to-select.
            wantsAnotherGarment = false
        }
    }

    /// Secondary save action surfaced on the details step when
    /// `selectedImage != nil && sam2Session != nil`. Flags the save
    /// path to loop back into `TapToSelectView` for the next garment
    /// instead of dismissing the Add Item sheet. No-op (plus a guard
    /// against accidental invocation) when SAM2 isn't available.
    func onSaveAndAddAnother(userId: UUID) async {
        guard sam2Session != nil else { return }
        wantsAnotherGarment = true
        await save(userId: userId)
    }

    /// Reset item-specific metadata (category, mask, touchup flags)
    /// while leaving `selectedImage`, `sourcePhotoId`, `sourcePhotoPath`,
    /// `sam2Session`, and `savedItemsFromSource` intact. Called from
    /// the save-success branch when the user picked "Save & add another
    /// garment" — the next tap-to-select pass runs against the same
    /// captured image and reuses the cached SAM2 pixel buffer.
    ///
    /// `processedImage` is intentionally kept: its `originalData` and
    /// `thumbnailData` fields describe the source capture (same for
    /// every garment), and `onTapToSelectDone(_:)` routes the next
    /// mask through `imageService.updateMasked(...)` which needs a
    /// non-nil `ProcessedImage` to swap the mask into.
    private func resetKeepingSource() {
        category = .top
        subcategory = .tshirt
        texture = nil
        fitAttribute = nil
        selectedSeasons = Set(Season.allCases)
        selectedOccasions = [.casual]
        errorMessage = nil
        wantsAnotherGarment = false
        isAutoCropped = false
        isProcessing = false
        isShowingTouchup = false
        currentStep = .details
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
        // Phase 4 multi-garment loop state — always wiped on full reset
        // (vs `resetKeepingSource()` which deliberately preserves these).
        sourcePhotoId = nil
        sourcePhotoPath = nil
        sam2Session = nil
        savedItemsFromSource = 0
        wantsAnotherGarment = false
        // Cancel any in-flight session load so a sheet dismissal mid-
        // processing doesn't leak the MLModel load into the background.
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
    }
}
