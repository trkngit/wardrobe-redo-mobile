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

    /// Snapshot of attribute values pre-filled from a proposal's ML
    /// predictions at the start of the details step. Keyed by field name
    /// (`"category"`, `"subcategory"`, `"texture"`, `"fit"`, `"seasons"`,
    /// `"occasions"`); value is the enum rawValue (seasons/occasions are
    /// joined with `,`). Compared against the final user-edited values
    /// on save to power correction-rate telemetry (Phase 7 of the
    /// auto-attribute-detection plan). Empty outside an active details
    /// step or when no pre-fill cleared the confidence threshold.
    var detectedAttributes: [String: String] = [:]

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

    /// In-flight processing pipeline (Vision → optional SAM2-auto →
    /// color extraction). Stored so the loading-popup Cancel button
    /// can preempt it via `cancelProcessing()`. The wrapped body
    /// checks `Task.isCancelled` after each await so a cancel rolls
    /// the UI back to the photo step even if the underlying
    /// `processImage` continues briefly in the background.
    private var processingTask: Task<Void, Never>?

    /// Brief "Cancelled" pill shown at the bottom of `AddItemView`
    /// after the user taps Cancel on the analyzing popup. Confirms the
    /// action took effect (a silent rollback to the photo step would
    /// leave the user wondering whether the cancel was registered).
    /// Auto-clears via `cancellationDismissTask` after ~1.8 s.
    var cancellationToastVisible: Bool = false

    /// Auto-dismiss handle for the cancellation toast. Stored so a
    /// rapid second cancel resets the timer instead of letting the
    /// first dismiss fire mid-display, and so `reset()` can drop the
    /// pill cleanly when the sheet closes.
    private var cancellationDismissTask: Task<Void, Never>?

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

    // Phase 5: multi-garment proposals (feature-flagged)

    /// Proposals returned by `MultiGarmentProposalService` via
    /// `ImageService.processImage`. Nil when detection was skipped
    /// (flag off, extractor missing) or returned 0/1 items — either case
    /// falls through to the existing single-item tap-to-select flow.
    /// `count >= 2` is the trigger for `isShowingMultiPick`.
    var proposals: [MaskProposal]?

    /// IDs the user has currently checked on `MultiGarmentTapToSelectView`.
    /// Seeded to "all selected" when proposals first arrive — most users
    /// will want most items, so unchecking is cheaper than checking.
    var selectedProposalIDs: Set<MaskProposal.ID> = []

    /// FIFO queue of proposals the user confirmed, scored-descending.
    /// Drives the sequential per-item details loop: each successful save
    /// pops the next one into `currentProposal` + `.details`. Empty when
    /// not in a batch.
    var pendingProposalQueue: [MaskProposal] = []

    /// Proposal currently being detailed. Non-nil only while a batch is
    /// in flight; nil in single-item flows. Drives the "Skip this item"
    /// toolbar action's visibility.
    var currentProposal: MaskProposal?

    /// Controls the full-screen `MultiGarmentTapToSelectView` cover.
    /// Raised when ≥2 proposals land and the feature flag is on;
    /// lowered by confirm / escape / cancel / start-next.
    var isShowingMultiPick: Bool = false

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

        // Wrap the heavy work in a `Task` so the loading-popup Cancel
        // button can preempt it via `cancelProcessing()`. The public
        // method still awaits the task's value so existing test
        // contracts (post-conditions visible after the call returns)
        // are preserved on the happy path.
        processingTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let processed = await self.imageService.processImage(image)
            guard !Task.isCancelled else {
                sessionTask.cancel()
                self.sessionLoadTask = nil
                return
            }
            await self.applyProcessedFromLibrary(processed, sessionTask: sessionTask)
        }
        processingTask = task
        await task.value
        processingTask = nil
    }

    /// Post-processing branch for library-picked images. As of the
    /// "tap-to-select-first" reorg, both library and camera flows now
    /// open `TapToSelectView` immediately after processing — tap-to-
    /// select is pre-populated with the auto-detected mask so the
    /// happy-path user just hits "Use this crop" once, while users
    /// who got a bad auto-mask can refine with taps before
    /// proceeding.
    private func applyProcessedFromLibrary(
        _ processed: ProcessedImage?,
        sessionTask: Task<(any SAM2Session)?, Never>
    ) async {
        guard let processed else {
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
        routeAfterProcessing(processed: processed)
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

        // See `onPhotoSelected()` for the rationale of the wrapping
        // `processingTask` — same cancel-via-popup mechanism applies.
        processingTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let processed = await self.imageService.processImage(image)
            guard !Task.isCancelled else {
                sessionTask.cancel()
                self.sessionLoadTask = nil
                return
            }
            await self.applyProcessedFromCamera(processed, sessionTask: sessionTask)
        }
        processingTask = task
        await task.value
        processingTask = nil
    }

    /// Post-processing branch for camera captures. As of the
    /// "tap-to-select-first" reorg, both library and camera flows now
    /// open `TapToSelectView` immediately after processing — see
    /// `applyProcessedFromLibrary` for the rationale.
    private func applyProcessedFromCamera(
        _ processed: ProcessedImage?,
        sessionTask: Task<(any SAM2Session)?, Never>
    ) async {
        guard let processed else {
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
        routeAfterProcessing(processed: processed)
    }

    /// Single routing gate for post-processing: when ≥2 proposals came
    /// back and the feature flag is on, hand off to the multi-pick
    /// cover; otherwise (flag off, 0-1 proposals, or extractor missing)
    /// route to the existing single-item tap-to-select flow. Keeps
    /// library + camera branches structurally identical so the single
    /// rule change lives in one place.
    ///
    /// Belt-and-suspenders: `ImageService` already gates the proposal
    /// population on `FeatureFlags.isMultiGarmentEnabled`, but a stale
    /// `ProcessedImage` (e.g. injected from a test with proposals
    /// pre-populated) shouldn't be able to route past the gate at this
    /// later stage either.
    private func routeAfterProcessing(processed: ProcessedImage) {
        if FeatureFlags.isMultiGarmentEnabled,
           let props = processed.proposals,
           props.count >= 2 {
            proposals = props
            // Start with every proposal selected — users typically want
            // most items from a multi-garment photo, so unchecking is
            // cheaper than checking each from scratch.
            selectedProposalIDs = Set(props.map(\.id))
            logger.info("multiGarment.show: \(props.count) proposals, flag on")
            isShowingMultiPick = true
        } else {
            isShowingTapToSelect = true
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
        // Drop stale proposal state so a second photo doesn't inherit
        // the prior capture's queue / selection.
        proposals = nil
        selectedProposalIDs = []
        pendingProposalQueue = []
        currentProposal = nil
        isShowingMultiPick = false
    }

    /// User cancelled out of the camera view without capturing anything.
    /// Reset the capture method so the next interaction is fresh.
    func onCameraCancelled() {
        isShowingCamera = false
        captureMethod = .library
    }

    /// User tapped Cancel on the analyzing-popup overlay while
    /// `isProcessing == true`. Best-effort: cancels both in-flight
    /// tasks (session-load + the processing wrap), wipes the
    /// processing flags, and rolls the step back to `.photo` so the
    /// user can pick a different image. The underlying `processImage`
    /// may continue briefly in the background (Vision / SAM2 don't
    /// check cancellation themselves), but its result is dropped via
    /// the `Task.isCancelled` guard inside the wrap so no further UI
    /// state mutates after this returns.
    func cancelProcessing() {
        processingTask?.cancel()
        sessionLoadTask?.cancel()
        processingTask = nil
        sessionLoadTask = nil
        isProcessing = false
        currentStep = .photo
        errorMessage = nil
        // Clear the selected image so the user gets a clean next-pick
        // experience instead of seeing the cancelled photo lingering
        // in the photo step's preview area.
        selectedImage = nil
        selectedPhoto = nil

        // Flash a brief "Cancelled" pill so the user gets explicit
        // feedback that the cancel landed — a silent rollback would
        // leave them wondering whether the tap registered. Reset the
        // dismiss timer if a previous toast was still on screen.
        cancellationToastVisible = true
        cancellationDismissTask?.cancel()
        cancellationDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.cancellationToastVisible = false
            self.cancellationDismissTask = nil
        }
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

    /// User tapped "Refine with brush" inside `TapToSelectView` — the
    /// forward-direction counterpart to `onTroubleCropping`. Pivots from
    /// the tap/point-based selection UI over to the pixel-level brush
    /// editor in `MaskTouchupView` while keeping all per-capture state
    /// (selectedImage, processedImage, sam2Session) intact. The brush
    /// editor's Done callback already routes to `.details`, so this
    /// detour rejoins the main flow seamlessly.
    ///
    /// Emits an `addItem.refineWithBrush` log event so the dev can
    /// gauge real-world brush usage via Console.app
    /// (`subsystem:com.wardroberedo category:AddItem`) and decide
    /// whether the brush surface is worth keeping. Punch-list item
    /// per `unified-mapping-honey.md` — if usage stays below ~5% of
    /// saves over a few weeks, consider removing the detour entirely.
    func onTapToSelectRequestTouchup() {
        logger.info("addItem.refineWithBrush: user invoked brush detour from tap-to-select")
        isShowingTapToSelect = false
        isShowingTouchup = true
    }

    /// User tapped "Use this crop" in `TapToSelectView`. Rebuild
    /// `ProcessedImage` from the chosen mask so the saved palette
    /// matches, then route straight to `.details`. The brush-touchup
    /// sheet is no longer auto-opened here — users who want to brush
    /// refinements reach it via the "Refine with brush" button on
    /// the tap-to-select toolbar instead.
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
        // auto-cropped badge so `.details` doesn't surface it.
        isAutoCropped = false
        currentStep = .details
    }

    /// User backed out of `TapToSelectView`. Routes to `.details` with
    /// whatever mask the auto-extraction produced, so cancelling means
    /// "skip the manual selection, accept the auto crop" rather than
    /// losing the processing work entirely.
    func onTapToSelectCancelled() {
        isShowingTapToSelect = false
        currentStep = .details
    }

    // MARK: - Phase 5 multi-garment multi-pick

    /// User tapped "Save N items" on `MultiGarmentTapToSelectView`. Takes
    /// the current checkbox selection, orders it score-descending so the
    /// most confident garment is detailed first (matching the display
    /// order), and starts the sequential details loop.
    func onMultiPickConfirmed() {
        guard let proposals else { return }
        pendingProposalQueue = proposals
            .filter { selectedProposalIDs.contains($0.id) }
            .sorted { $0.detectionScore > $1.detectionScore }
        logger.info("multiGarment.confirm: \(self.pendingProposalQueue.count) items queued")
        startNextProposal()
    }

    /// Escape hatch. User tapped "Use full photo" on the multi-pick
    /// screen — drops all proposals and routes to the existing single-
    /// item tap-to-select flow. Telemetry-logged so we can measure how
    /// often users bail on the multi-pick UX.
    func onMultiPickUseFullPhoto() {
        logger.info("multiGarment.escape: user chose 'Use full photo'")
        proposals = nil
        selectedProposalIDs = []
        pendingProposalQueue = []
        currentProposal = nil
        isShowingMultiPick = false
        isShowingTapToSelect = true
    }

    /// User tapped Cancel on the multi-pick toolbar. Unlike "Use full
    /// photo" (which keeps the capture and falls through to single-item
    /// selection), this abandons the capture entirely and drops back to
    /// the photo step so the user can pick a different source.
    func onMultiPickCancelled() {
        logger.info("multiGarment.cancel: user dismissed multi-pick")
        isShowingMultiPick = false
        proposals = nil
        selectedProposalIDs = []
        pendingProposalQueue = []
        currentProposal = nil
        currentStep = .photo
    }

    /// "Skip this item" toolbar action on the details step, visible only
    /// while a batch is in flight (`currentProposal != nil`). Pops the
    /// next proposal without saving the current one; if the queue is
    /// empty this becomes a no-save finish like the user just tapped
    /// Cancel on the last item.
    func onSkipCurrentProposal() {
        logger.info("multiGarment.skip: skipping current proposal, \(self.pendingProposalQueue.count) remaining")
        startNextProposal()
    }

    /// Pop the next proposal off the queue and prepare the details step
    /// for it. Swaps the proposal's cutout into `processedImage` so the
    /// details preview shows the correct garment, resets item-specific
    /// metadata to defaults, and lowers the multi-pick cover.
    ///
    /// When the queue is empty this routes to one of:
    /// - `didSave = true` if at least one item was saved (batch done)
    /// - `.photo` step if nothing was saved (user skipped all)
    private func startNextProposal() {
        guard !pendingProposalQueue.isEmpty else {
            isShowingMultiPick = false
            isShowingTapToSelect = false
            currentProposal = nil
            if savedItemsFromSource > 0 {
                // At least one garment landed — treat the batch as done
                // and dismiss the sheet like any normal save flow.
                didSave = true
            } else {
                // Batch ended without saving anything (user skipped
                // through everything). Drop back to photo step instead
                // of silently dismissing — friendlier for a restart.
                currentStep = .photo
            }
            return
        }
        let next = pendingProposalQueue.removeFirst()
        currentProposal = next
        // Splice the proposal's cutout into processedImage so the
        // details preview renders the right garment. PNG preserves the
        // transparent background — JPEG would flatten it.
        if let current = processedImage {
            processedImage = ProcessedImage(
                originalData: current.originalData,
                thumbnailData: current.thumbnailData,
                maskedData: next.maskedImage.pngData(),
                extractionConfidence: next.confidence,
                extractionMethod: .multiGarmentRFDETR,
                dominantColors: current.dominantColors,
                // Clear so the post-save branch doesn't re-route into
                // multi-pick — this proposal is already being processed.
                proposals: nil
            )
        }
        // Pre-fill item metadata from the proposal's ML predictions
        // (threshold-gated) and snapshot which fields the ML drove so
        // `save(userId:)` can diff against user edits for correction
        // telemetry. Falls back to the legacy defaults when no field
        // clears the threshold — identical behaviour to the old hard
        // reset in that case.
        applyPrefill(from: next)
        errorMessage = nil
        isAutoCropped = false
        isProcessing = false
        isShowingTouchup = false
        isShowingTapToSelect = false
        isShowingMultiPick = false
        currentStep = .details
    }

    /// Pre-fill category / subcategory / texture / fit / seasons /
    /// occasions from a proposal's ML predictions, respecting the
    /// per-field confidence threshold in `AttributePrefill`. Records a
    /// `detectedAttributes` snapshot so the save path can detect user
    /// corrections. Fields whose confidence doesn't clear the bar (or
    /// whose proposal prediction is nil) fall back to the legacy
    /// defaults — identical behaviour to the pre-Phase-0 hard reset.
    ///
    /// Gated by `FeatureFlags.isAttributeDetectionEnabled`. When the
    /// flag is off we short-circuit to the legacy hard-reset so a
    /// classifier regression in the wild can be killed remotely without
    /// an app update.
    private func applyPrefill(from proposal: MaskProposal) {
        guard FeatureFlags.isAttributeDetectionEnabled else {
            // Legacy behaviour: reset every picker to its hard-coded
            // default. Matches the pre-Phase-0 `startNextProposal` logic.
            category = .top
            subcategory = .tshirt
            texture = nil
            fitAttribute = nil
            selectedSeasons = Set(Season.allCases)
            selectedOccasions = [.casual]
            detectedAttributes = [:]
            return
        }

        var snapshot: [String: String] = [:]

        if let cat = proposal.predictedCategory,
           AttributePrefill.shouldPrefill(proposal.predictedCategoryConfidence) {
            category = cat
            snapshot["category"] = cat.rawValue
        } else {
            category = .top
        }

        // Subcategory prediction is already a conservative commit (nil
        // for ambiguous Fashionpedia classes, see
        // `ClothingSubcategory.fromFashionpediaClass`), so it doesn't
        // have its own confidence field. Guard on `category` match so a
        // prediction mismatch (e.g. predicted blazer→.suitJacket but
        // category fell back to .top) doesn't leave the picker stuck on
        // an invalid option.
        if let sub = proposal.predictedSubcategory, sub.category == category {
            subcategory = sub
            snapshot["subcategory"] = sub.rawValue
        } else {
            subcategory = defaultSubcategory(for: category)
        }

        if let tex = proposal.predictedTexture,
           AttributePrefill.shouldPrefill(proposal.predictedTextureConfidence) {
            texture = tex
            snapshot["texture"] = tex.rawValue
        } else {
            texture = nil
        }

        if let fit = proposal.predictedFit,
           AttributePrefill.shouldPrefill(proposal.predictedFitConfidence) {
            fitAttribute = fit
            snapshot["fit"] = fit.rawValue
        } else {
            fitAttribute = nil
        }

        if proposal.predictedSeasons.isEmpty {
            selectedSeasons = Set(Season.allCases)
        } else {
            selectedSeasons = Set(proposal.predictedSeasons)
            snapshot["seasons"] = proposal.predictedSeasons
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
        }

        if proposal.predictedOccasions.isEmpty {
            selectedOccasions = [.casual]
        } else {
            selectedOccasions = Set(proposal.predictedOccasions)
            snapshot["occasions"] = proposal.predictedOccasions
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
        }

        detectedAttributes = snapshot
    }

    /// Default picker selection for a category, used when the proposal
    /// didn't commit to a subcategory. Mirrors the category's first
    /// `availableSubcategories` entry (modulo the historical `.tshirt`
    /// default for `.top`, kept verbatim so existing behaviour is
    /// preserved pixel-for-pixel).
    private func defaultSubcategory(for category: ClothingCategory) -> ClothingSubcategory {
        switch category {
        case .top: return .tshirt
        case .bottom: return .jeans
        case .shoe: return .sneakers
        case .dress: return .casualDress
        case .outerwear: return .leatherJacket
        case .accessory: return .hat
        }
    }

    /// Diff the `applyPrefill` snapshot against the final user-edited
    /// form values to produce the provenance map persisted in
    /// `wardrobe_items.detected_attributes` (migration 00009). Each key
    /// maps to one of:
    ///
    ///   - `"ai"`                   — ML pre-filled this field AND the
    ///                                final saved value matches the
    ///                                pre-fill (user accepted).
    ///   - `"user"`                 — ML never pre-filled this field
    ///                                (below threshold or no prediction);
    ///                                whatever the user saved is their
    ///                                own answer.
    ///   - `"user_changed_from_ai"` — ML pre-filled AND the user edited
    ///                                or cleared the value before save.
    ///
    /// Fields the user never interacted with AND that ML never pre-filled
    /// are omitted from the map entirely — those carry no signal.
    ///
    /// Pure function for testability. Matches the rawValue / sorted-
    /// comma-join format produced by `applyPrefill(from:)` so snapshot
    /// and final value are comparable character-for-character.
    /// `nonisolated` because the helper touches only its arguments —
    /// no actor state — so tests can call it directly without hopping
    /// to the main actor.
    nonisolated static func computeAttributeProvenance(
        snapshot: [String: String],
        finalCategory: String,
        finalSubcategory: String,
        finalTexture: String?,
        finalFit: String?,
        finalSeasons: [String],
        finalOccasions: [String]
    ) -> [String: String] {
        let seasonsJoined = finalSeasons.sorted().joined(separator: ",")
        let occasionsJoined = finalOccasions.sorted().joined(separator: ",")

        let entries: [(key: String, snap: String?, final: String?)] = [
            ("category",    snapshot["category"],    finalCategory),
            ("subcategory", snapshot["subcategory"], finalSubcategory),
            ("texture",     snapshot["texture"],     finalTexture),
            ("fit",         snapshot["fit"],         finalFit),
            ("seasons",     snapshot["seasons"],     seasonsJoined.isEmpty ? nil : seasonsJoined),
            ("occasions",   snapshot["occasions"],   occasionsJoined.isEmpty ? nil : occasionsJoined),
        ]

        var result: [String: String] = [:]
        for entry in entries {
            switch (entry.snap, entry.final) {
            case (nil, nil):
                continue
            case (nil, _?):
                result[entry.key] = "user"
            case (_?, nil):
                result[entry.key] = "user_changed_from_ai"
            case let (snap?, fin?):
                result[entry.key] = (snap == fin) ? "ai" : "user_changed_from_ai"
            }
        }
        return result
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

        // Diff the `applyPrefill` snapshot against the final form values.
        // Produces a {field: "ai" | "user" | "user_changed_from_ai"} map
        // that lands in `wardrobe_items.detected_attributes` for
        // correction-rate telemetry (migration 00009).
        let provenance = Self.computeAttributeProvenance(
            snapshot: detectedAttributes,
            finalCategory: cat,
            finalSubcategory: subcat,
            finalTexture: tex,
            finalFit: fit,
            finalSeasons: seasons,
            finalOccasions: occasions
        )

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
                        occasions: occasions,
                        detectedAttributes: provenance
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

            if !pendingProposalQueue.isEmpty || currentProposal != nil {
                // Multi-pick batch in flight (queue has more items, or
                // we're saving the last one). `startNextProposal`
                // handles both branches: pop-and-detail, or dismiss
                // via `didSave = true` when the queue is empty. Takes
                // priority over the single-item `wantsAnotherGarment`
                // flag because batch progression is the stronger signal.
                startNextProposal()
            } else if shouldLoopAfter {
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
        detectedAttributes = [:]
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
        detectedAttributes = [:]
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
        // Phase 5 multi-pick state.
        proposals = nil
        selectedProposalIDs = []
        pendingProposalQueue = []
        currentProposal = nil
        isShowingMultiPick = false
        // Cancel any in-flight session load so a sheet dismissal mid-
        // processing doesn't leak the MLModel load into the background.
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        // Same for the processing wrap.
        processingTask?.cancel()
        processingTask = nil
        // Drop any pending toast — if the sheet is being torn down,
        // there's nothing to show feedback on.
        cancellationDismissTask?.cancel()
        cancellationDismissTask = nil
        cancellationToastVisible = false
    }
}
