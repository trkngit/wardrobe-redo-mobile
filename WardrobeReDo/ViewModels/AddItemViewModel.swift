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

    /// Build 47 — whether `category` reflects a genuine choice (either a
    /// high-confidence ML prefill OR an explicit user tap) vs. an
    /// internal placeholder default. When false, the Add details screen
    /// shows a "Choose a category" prompt instead of a pre-highlighted
    /// segment, and `canSave` stays false until the user picks — so the
    /// app never silently saves an item under a guessed category. Edit
    /// flows always have a known category, so `ItemFormView` defaults
    /// its binding to a constant `true` and is unaffected.
    var categoryConfirmed: Bool = false

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

    /// Build 45 — primary post-processing surface. Replaces
    /// `isShowingTapToSelect` as the default landing after auto-
    /// extraction. The preview screen shows the cutout with
    /// `[Use this] / [Refine if needed] / [Retake]` actions; the
    /// majority case (auto-detection got it right) is a one-tap
    /// confirm. Users who hit "Refine if needed" route into the
    /// existing tap-to-select view, so power-user / recovery cases
    /// are preserved.
    var isShowingPreview = false
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

    /// Total number of proposals queued for the current multi-pick
    /// batch. Stamped once when the user taps "Save N items" on the
    /// grid view and stays constant for the duration of the batch
    /// (saved + skipped + still-pending). Drives the per-batch
    /// progress bar at the top of `AddItemView`. Zero when no batch
    /// is in flight (single-item flow).
    var batchTotalCount: Int = 0

    /// Number of proposals the user explicitly skipped via "Skip this
    /// item" during the current batch. Combined with
    /// `savedItemsFromSource` to compute progress through the queue
    /// (saved + skipped = processed; total - processed = remaining).
    var batchSkippedCount: Int = 0

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

    /// IDs the user has currently checked on `MultiGarmentGridView`.
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

    /// Controls the full-screen `MultiGarmentGridView` cover.
    /// Raised when ≥2 proposals land and the feature flag is on;
    /// lowered by confirm / escape / cancel / start-next.
    var isShowingMultiPick: Bool = false

    // MARK: Phase 2 — approval-gallery "Save all" state

    /// Per-proposal category corrections from the approval gallery, keyed
    /// by proposal id. `MaskProposal` is an immutable value type, so a
    /// user's 1-tap category fix on a card lives here and is applied on top
    /// of `applyPrefill`'s ML seed in `startNextProposal`. Cleared when the
    /// batch ends or a fresh capture starts (`resetFastSaveAllState`).
    var proposalCategoryOverrides: [MaskProposal.ID: ClothingCategory] = [:]

    /// The single occasion the whole batch inherits — the gallery's one
    /// shared control. Applied to every item in the Save-all pass AFTER
    /// `applyPrefill`, so the user's batch choice wins over the ML seed.
    /// Defaults to the same `[.casual]` as the single-item flow.
    var sharedBatchOccasions: Set<Occasion> = [.casual]

    /// True while a "Save all N" pass is running: tells `startNextProposal`
    /// to commit each item via `save()` instead of stopping on the Fast
    /// Confirm card. Reset when the queue drains or the batch is abandoned.
    var isFastSaveAll: Bool = false

    /// The user id threaded through the Save-all loop so the recursive
    /// `save → startNextProposal → save` chain can call `save(userId:)`
    /// without re-plumbing the existing post-save loop anchor.
    var fastSaveUserId: UUID?

    // MARK: Phase 3 — add-flow speed metric

    /// Wall-clock start for the `addflow.interaction_ms` breadcrumb: stamped
    /// when processing completes (the user lands on an interactive surface)
    /// and read when the flow finishes (`didSave`). nil = no add-flow timing
    /// in progress. Stamped fresh per capture in `routeAfterProcessing`.
    var addFlowStartedAt: Date?

    // MARK: - Dependencies

    let imageService: any ImageServiceProtocol
    let wardrobeRepository: any WardrobeRepositoryProtocol
    /// Per-proposal palette extractor. Injected via `init` so tests can
    /// substitute a deterministic stub instead of running the real
    /// k-means classifier (whose output for synthetic test images is
    /// brittle across colour spaces). Production default is the shared
    /// `ColorExtractionService`.
    let colorExtractor: any ColorExtracting
    /// Exposed so the Phase 3 TapToSelectView can call back into the
    /// same extractor instance as the rest of the pipeline (no duplicate
    /// model loads, no cold-starts per tap).
    let clothingExtractor: any ClothingExtracting
    /// Persistent retry queue for server-side inserts. On the happy path
    /// `wardrobeRepository.insertItem` runs synchronously and the queue is
    /// never touched. If the insert throws a *retryable* error after the
    /// repo's own in-process `withRetry` has exhausted, we enqueue the
    /// pending item here so a later `drain()` (triggered on next app
    /// foreground / cold start) can replay it. Non-retryable errors
    /// bypass the queue and surface to the user as today. Default is the
    /// process-wide shared singleton so test instances can inject their
    /// own queue without leaking state.
    let uploadQueue: UploadQueue
    let logger = Logger(subsystem: "com.wardroberedo", category: "AddItem")

    init(
        imageService: any ImageServiceProtocol = ImageService(),
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository(),
        colorExtractor: any ColorExtracting = ColorExtractionService(),
        clothingExtractor: any ClothingExtracting = ClothingExtractionService(),
        uploadQueue: UploadQueue = UploadQueue.shared
    ) {
        self.imageService = imageService
        self.wardrobeRepository = wardrobeRepository
        self.colorExtractor = colorExtractor
        self.clothingExtractor = clothingExtractor
        self.uploadQueue = uploadQueue
    }

    // MARK: - Computed

    var extractedColors: [ColorProfile] {
        processedImage?.dominantColors.map { $0.toColorProfile() } ?? []
    }

    var availableSubcategories: [ClothingSubcategory] {
        ClothingSubcategory.subcategories(for: category)
    }

    var canSave: Bool {
        // Build 52 — Fast Add commits a best-guess category every time, so
        // Save is enabled immediately (the user fixes a wrong guess in one
        // tap on the confirm card). When Fast Add is off, fall back to the
        // TF47 rule: require an explicitly-chosen category so we never
        // persist an item under a placeholder guess.
        guard processedImage != nil, !isSaving else { return false }
        return FeatureFlags.isFastAddEnabled || categoryConfirmed
    }

    // MARK: - Actions

    func onPhotoSelected() async {
        guard let item = selectedPhoto else { return }

        // Build 30 — breadcrumb logging at every step of the photo
        // pipeline. After Build 29 reduced peak memory via the lazy
        // CGImageSource downsample, the user reports the app still
        // crashes during library/camera photo flow on real devices.
        // Without device logs we can't pinpoint which step dies, so
        // we instrument every transition. These show up in Console.app
        // when the device is wired up + in Sentry breadcrumbs.
        logger.info("library.onPhotoSelected: start")

        captureMethod = .library
        isProcessing = true
        errorMessage = nil
        currentStep = .analysis

        guard let image = await imageService.loadImage(from: item) else {
            logger.error("library.loadImage: returned nil")
            errorMessage = String(localized: "Couldn't load that image. Try another one.")
            currentStep = .photo
            isProcessing = false
            return
        }
        logger.info("library.loadImage: ok, size=\(image.size.width, privacy: .public)x\(image.size.height, privacy: .public)")

        selectedImage = image
        stampFreshCapture()

        // Build 40 — SAM2 session load deferred to `applyProcessedFromLibrary`.
        // Previously kicked off here in parallel with Vision processing
        // ("session isn't consumed until tap-to-select, so hide the cost"
        // — was the prior rationale). In practice the ~100 MB MLModel
        // load stacked on top of the picker's bitmap + Vision buffers,
        // pushing `phys_footprint` past the foreground jetsam limit on
        // iPhone 12-class devices DURING the "Analyzing…" window. By
        // moving the load AFTER processing completes successfully, the
        // peak memory footprint drops by the size of the model. Cost:
        // ~1 s longer on the analyzing spinner — same screen, same UX
        // state, just a slightly longer wait.
        //
        // Cancel any in-flight session load from a PRIOR capture
        // (rapid back-to-back photo selections) so we don't leave a
        // dangling MLModel load running.
        sessionLoadTask?.cancel()
        sessionLoadTask = nil

        // Wrap the heavy work in a `Task` so the loading-popup Cancel
        // button can preempt it via `cancelProcessing()`. The public
        // method still awaits the task's value so existing test
        // contracts (post-conditions visible after the call returns)
        // are preserved on the happy path. The timeout race inside
        // `processWithTimeout` ensures a hung Vision/SAM2 stack
        // surfaces an error after 30s instead of stranding the user
        // on an infinite spinner.
        processingTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("library.processWithTimeout: start")
            let outcome = await self.processWithTimeout(image)
            self.logger.info("library.processWithTimeout: done outcome=\(String(describing: outcome), privacy: .public)")
            guard !Task.isCancelled else {
                return
            }
            switch outcome {
            case .completed(let processed):
                self.logger.info("library.apply: processed=\(processed != nil ? "ok" : "nil", privacy: .public)")
                await self.applyProcessedFromLibrary(processed, sourceImage: image)
            case .timedOut:
                self.logger.error("library.timeout: 30s elapsed")
                self.handleProcessingTimeout()
            }
        }
        processingTask = task
        await task.value
        processingTask = nil
        logger.info("library.onPhotoSelected: end")
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
        sourceImage: UIImage
    ) async {
        guard let processed else {
            errorMessage = String(localized: "Couldn't process that image. Try another one.")
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        // Build 40 — load SAM2 session here, AFTER processing succeeded,
        // instead of in parallel with `processWithTimeout` (see the
        // `onPhotoSelected` comment above for the memory rationale).
        // The ~100 MB model load now happens against a heap that's
        // already shed the Vision/Core Image temp buffers. Telemetry
        // brackets record the heap delta so the next crash report can
        // be matched against the actual jetsam ceiling on this device.
        logger.info("sam2.sessionLoad.start mem=\(MemoryMonitor.currentHeapUsageMB, privacy: .public) caller=library")
        let session = await clothingExtractor.makeSession(for: sourceImage)
        logger.info("sam2.sessionLoad.end mem=\(MemoryMonitor.currentHeapUsageMB, privacy: .public) caller=library success=\(session != nil, privacy: .public)")
        sam2Session = session
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
        // Build 47 — any user interaction with the category control is an
        // explicit choice, so the item becomes saveable. Covers both the
        // confirmed-state segmented picker (onChange) and is reinforced by
        // the unconfirmed-state chips (which set the binding directly).
        categoryConfirmed = true
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
        // Build 30 — same breadcrumb instrumentation as
        // `onPhotoSelected`. See that method for the rationale.
        logger.info("camera.onPhotoCaptured: start size=\(image.size.width, privacy: .public)x\(image.size.height, privacy: .public)")

        isShowingCamera = false
        // Build 26 / Bug F — downsample the raw capture before
        // anything else touches it. A fresh iPhone capture is
        // ~12 MP / ~50 MB decoded; running it through SAM2 session
        // load + the processing-with-timeout task in parallel was
        // pushing real devices past the foreground app memory limit
        // and the OS was killing the process. The library flow
        // doesn't crash because PhotosPicker already returns a
        // pre-downsized representation. We mirror that here.
        // 2048 px on the long edge is well above SAM2's 1024 px
        // input resolution, so cutout quality is unaffected.
        //
        // Build 29 moved the actual downsample upstream into the
        // AVCapture delegate so this call is typically a no-op
        // (input is already ≤ 2048 px). Defense in depth.
        let downsampled = ImageDownsampler.downsampled(image)
        logger.info("camera.downsampled: size=\(downsampled.size.width, privacy: .public)x\(downsampled.size.height, privacy: .public)")
        selectedImage = downsampled
        stampFreshCapture()
        isProcessing = true
        errorMessage = nil
        currentStep = .analysis

        // Build 40 — SAM2 session load deferred to `applyProcessedFromCamera`.
        // See `onPhotoSelected` for the full memory rationale; same
        // reasoning applies on the camera path. Just cancel any in-
        // flight session from a prior capture before continuing.
        sessionLoadTask?.cancel()
        sessionLoadTask = nil

        // See `onPhotoSelected()` for the rationale of the wrapping
        // `processingTask` — same cancel-via-popup mechanism applies.
        // The timeout race inside `processWithTimeout` matches the
        // library path so a hung capture also surfaces an error.
        // Bug F — pass the DOWNSAMPLED image, not the raw capture.
        // The raw `image` is now released as soon as this function
        // returns; only the 2048 px copy stays in memory.
        processingTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("camera.processWithTimeout: start")
            let outcome = await self.processWithTimeout(downsampled)
            self.logger.info("camera.processWithTimeout: done outcome=\(String(describing: outcome), privacy: .public)")
            guard !Task.isCancelled else {
                return
            }
            switch outcome {
            case .completed(let processed):
                self.logger.info("camera.apply: processed=\(processed != nil ? "ok" : "nil", privacy: .public)")
                await self.applyProcessedFromCamera(processed, sourceImage: downsampled)
            case .timedOut:
                self.logger.error("camera.timeout: 30s elapsed")
                self.handleProcessingTimeout()
            }
        }
        processingTask = task
        await task.value
        processingTask = nil
        logger.info("camera.onPhotoCaptured: end")
    }

    /// Post-processing branch for camera captures. As of the
    /// "tap-to-select-first" reorg, both library and camera flows now
    /// open `TapToSelectView` immediately after processing — see
    /// `applyProcessedFromLibrary` for the rationale.
    private func applyProcessedFromCamera(
        _ processed: ProcessedImage?,
        sourceImage: UIImage
    ) async {
        guard let processed else {
            errorMessage = String(localized: "Couldn't process that photo. Try again.")
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        isAutoCropped = (processed.extractionMethod == .sam2Auto)
        // Build 40 — SAM2 session load happens here instead of in
        // parallel with the Vision pipeline. See
        // `applyProcessedFromLibrary` for the rationale.
        logger.info("sam2.sessionLoad.start mem=\(MemoryMonitor.currentHeapUsageMB, privacy: .public) caller=camera")
        let session = await clothingExtractor.makeSession(for: sourceImage)
        logger.info("sam2.sessionLoad.end mem=\(MemoryMonitor.currentHeapUsageMB, privacy: .public) caller=camera success=\(session != nil, privacy: .public)")
        sam2Session = session
        sessionLoadTask = nil
        // Downsample the retained UIImage — see `onPhotoSelected()`
        // for the rationale.
        if let resized = UIImage(data: processed.originalData) {
            selectedImage = resized
        }
        isProcessing = false
        routeAfterProcessing(processed: processed)
    }

    // MARK: - Photo-processing timeout (Phase 1 polish)

    /// Outcome of `processWithTimeout` — distinguishes a real
    /// completion (whose payload may itself be nil = "couldn't
    /// process") from a hung-pipeline timeout. Without this, the user
    /// sees the same generic "Couldn't process that photo" message in
    /// both cases — so the analyzing popup looks like it failed
    /// instantly even though it spun for 30 seconds first.
    enum PhotoProcessingOutcome: Sendable {
        case completed(ProcessedImage?)
        case timedOut
    }

    /// Default ceiling for image processing. 30 seconds is comfortably
    /// past the 99th-percentile success path on real devices and well
    /// under the iOS watchdog budget.
    static let photoProcessingTimeoutSeconds: Int = 30

    /// Race the async `imageService.processImage(_:)` call against a
    /// configurable timeout. The Vision/SAM2 framework path can hang
    /// in rare cases (memory pressure, corrupt model, malformed
    /// orientation metadata) — without this race the user sees an
    /// infinite spinner with no error and no escape except force-quit.
    /// On timeout, the inner processing task continues in the
    /// background but its eventual result is discarded; we surface the
    /// `.timedOut` outcome so the caller can show an actionable error.
    private func processWithTimeout(
        _ image: UIImage,
        seconds: Int = AddItemViewModel.photoProcessingTimeoutSeconds
    ) async -> PhotoProcessingOutcome {
        let imageService = self.imageService
        return await withTaskGroup(of: PhotoProcessingOutcome.self) { group in
            group.addTask {
                let processed = await imageService.processImage(image)
                return .completed(processed)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            group.cancelAll()
            return result
        }
    }

    /// Shared timeout-handler for both library + camera paths: cancels
    /// any prior SAM2 session load (defense-in-depth for rapid back-
    /// to-back captures), surfaces an actionable error message that
    /// names the underlying cause, and drops the user back to the
    /// photo step where a retry is one tap away.
    ///
    /// Build 40 — the in-flight `sessionTask` parameter went away when
    /// SAM2 load moved to `applyProcessedFrom{Library,Camera}`. The
    /// only session task that could still be live here is a leftover
    /// from a prior capture; cancel it as a precaution.
    private func handleProcessingTimeout() {
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        errorMessage = String(localized: "Analysis took too long. Try a clearer photo or smaller capture.")
        currentStep = .photo
        isProcessing = false
        logger.warning("photo.processing.timedOut after \(Self.photoProcessingTimeoutSeconds, privacy: .public)s")
    }

    // MARK: - Batch persistence (multi-pick crash recovery)

    /// Marker so the AddItemView's onAppear knows the VM was just
    /// restored from disk vs freshly initialised. Cleared by the
    /// view after it shows the resume toast (or the user takes any
    /// action). UI-only signal — not persisted.
    var didJustRestoreBatch: Bool = false

    /// Snapshot the current batch to disk. Called from inside
    /// `startNextProposal` (post-mutation) so every queue movement
    /// is captured atomically. No-op when no batch is in flight
    /// (`batchTotalCount == 0` and `currentProposal == nil`).
    func persistBatchSnapshot() {
        guard batchTotalCount > 0,
              currentProposal != nil || !pendingProposalQueue.isEmpty
        else {
            return
        }
        guard let userId = currentUserIdForPersistence else { return }
        guard let sourcePhotoId else { return }

        let queue: [PersistedProposal] = pendingProposalQueue.compactMap { PersistedProposal(from: $0) }
        let current: PersistedProposal? = currentProposal.flatMap { PersistedProposal(from: $0) }
        let sourcePNG = selectedImage?.pngData()

        let snapshot = BatchSnapshot(
            userId: userId,
            sourcePhotoId: sourcePhotoId,
            sourcePhotoPath: sourcePhotoPath,
            sourcePhotoPNG: sourcePNG,
            createdAt: Date(),
            total: batchTotalCount,
            savedCount: savedItemsFromSource,
            skippedCount: batchSkippedCount,
            queue: queue,
            currentProposal: current
        )
        BatchPersistenceService.save(snapshot)
    }

    /// Restore an in-flight multi-pick batch from disk if one exists,
    /// belongs to the current user, and isn't stale. Called from
    /// `AddItemView.onAppear`. Returns `true` when a batch was
    /// restored so the view can show the "Resumed your batch" toast.
    /// Idempotent — calling twice in a row finds nothing the second
    /// time because the first call consumes (or clears) the snapshot.
    @discardableResult
    func restorePersistedBatchIfNeeded(currentUserId: UUID) async -> Bool {
        guard let snapshot = BatchPersistenceService.load() else { return false }
        guard snapshot.userId == currentUserId else {
            logger.info("batch.restore.skipped: signed-in user mismatch")
            BatchPersistenceService.clear()
            return false
        }

        // Hydrate the queue + current proposal back from PNG bytes.
        let queue = snapshot.queue.compactMap { $0.toProposal() }
        guard let current = snapshot.currentProposal?.toProposal() else {
            // Without a current proposal there's nothing to detail
            // — treat as a corrupt snapshot.
            logger.warning("batch.restore.skipped: no current proposal in snapshot")
            BatchPersistenceService.clear()
            return false
        }

        // Restore VM state. Order matters: counters first so the
        // progress bar shows correct values when `currentStep`
        // changes; then queue + currentProposal; then the picker
        // state via applyPrefill.
        sourcePhotoId = snapshot.sourcePhotoId
        sourcePhotoPath = snapshot.sourcePhotoPath
        savedItemsFromSource = snapshot.savedCount
        batchTotalCount = snapshot.total
        batchSkippedCount = snapshot.skippedCount
        pendingProposalQueue = queue
        currentProposal = current

        // Restore the source photo (used as the fallback image when
        // currentProposal.maskedImage hasn't loaded yet, plus the
        // upload path for garments 2..N).
        if let sourceData = snapshot.sourcePhotoPNG, let img = UIImage(data: sourceData) {
            selectedImage = img
        }

        // Build 46 — reconstruct `processedImage` from the restored
        // source + the current proposal's cutout. Without this,
        // `processedImage` stays nil after a restore, which made
        // `canSave` false (Save button disabled) and `save()`
        // early-return — the user saw their selection come back but
        // couldn't save it (the TestFlight report). The persisted
        // snapshot deliberately doesn't store the encoded
        // ProcessedImage (it would bloat the JSON), so we rebuild it
        // here from the images it does store.
        if let source = selectedImage {
            processedImage = await imageService.reconstructProcessedImage(
                source: source,
                maskedImage: current.maskedImage,
                confidence: current.confidence,
                method: .multiGarmentRFDETR
            )
            if processedImage == nil {
                logger.warning("batch.restore.reconstructFailed: could not rebuild ProcessedImage")
            }
        }

        // Pre-fill the form from the restored proposal — same path
        // a fresh batch follows.
        applyPrefill(from: current)

        // Land on the details step so the user picks up where they
        // left off.
        currentStep = .details
        isShowingMultiPick = false
        isShowingTapToSelect = false
        isShowingPreview = false
        didJustRestoreBatch = true

        logger.info("batch.restore.success: \(queue.count, privacy: .public) pending, \(snapshot.savedCount, privacy: .public) already saved, processedImage=\(self.processedImage != nil ? "rebuilt" : "nil", privacy: .public)")
        return true
    }

    /// Captured from the auth layer at runtime — the persistence
    /// service stamps this onto each snapshot so a later sign-in as
    /// a different user discards the prior batch instead of
    /// resurrecting it. Set via `setCurrentUserIdForPersistence(_:)`
    /// from the view layer where `AppState` is in scope. Defaults to
    /// nil so single-item flows (no batch) bypass persistence
    /// entirely without needing the user id.
    private(set) var currentUserIdForPersistence: UUID?

    /// Stamp the VM with the current authenticated user's ID so
    /// `persistBatchSnapshot` can include it. Called from
    /// `AddItemView.onAppear` once `AppState.currentUser` is
    /// available.
    func setCurrentUserIdForPersistence(_ userId: UUID?) {
        currentUserIdForPersistence = userId
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
        // Phase 3 — start the add-speed metric clock. Processing is done and
        // the user is about to interact (the Fast Confirm card, the multi-pick
        // gallery, or the legacy preview); `logAddFlowInteractionMetric` reads
        // this when the flow finishes at `didSave`.
        addFlowStartedAt = Date()
        if FeatureFlags.isMultiGarmentEnabled,
           let props = processed.proposals,
           props.count >= 2 {
            proposals = props
            // Start with every proposal selected — users typically want
            // most items from a multi-garment photo, so unchecking is
            // cheaper than checking each from scratch.
            selectedProposalIDs = Set(props.map(\.id))
            logger.info("routing.decision dest=multiGarmentGrid proposals=\(props.count, privacy: .public)")
            isShowingMultiPick = true
        } else if FeatureFlags.isFastAddEnabled {
            // Build 52 (Fast Add) — fold Preview & Confirm into the inline
            // Fast Confirm card: land directly on `.details` instead of the
            // full-screen cover, so the happy path is one screen, not two.
            //
            // A single-garment photo still produces exactly ONE MaskProposal
            // (multi-garment detection runs regardless of count and only the
            // `count >= 2` gate above routes to the grid), whose
            // `predictedCategory` this else-branch would otherwise discard.
            // Seed the card's best-guess attributes from it via the SAME
            // `applyPrefill` the multi-pick path uses, so single-item adds get
            // a real ML category + rules-derived texture / seasons / occasions
            // instead of the bare `.top` placeholder. When multi-garment
            // detection is off there's no proposal, so commit a confirmed
            // neutral default the user corrects in one tap (keeps `canSave`
            // honest and ProportionBalance covered via `.regular` fit).
            //
            // Do NOT also raise `isShowingPreview` here — the inline card and
            // the full-screen cover would both present (double UI).
            if let proposal = processed.proposals?.first {
                applyPrefill(from: proposal)
            } else {
                categoryConfirmed = true
                fitAttribute = .regular
            }
            logger.info("routing.decision dest=fastConfirmCard hasProposal=\(processed.proposals?.first != nil, privacy: .public) method=\(processed.extractionMethod?.rawValue ?? "nil", privacy: .public)")
            currentStep = .details
        } else {
            // Build 45 — auto-extraction completed; land on the new
            // Preview & Confirm screen instead of TapToSelectView. The
            // user gets a single-tap "Use this" affordance on the happy
            // path; tap-to-select is reachable via "Refine if needed".
            logger.info("routing.decision dest=previewAndConfirm method=\(processed.extractionMethod?.rawValue ?? "nil", privacy: .public) confidence=\(processed.extractionConfidence?.rawValue ?? "nil", privacy: .public)")
            isShowingPreview = true
        }
    }

    /// Phase 3 — emit the primary add-speed metric: wall-clock from
    /// processing-complete (`routeAfterProcessing`) to the flow finishing
    /// (`didSave`), plus how many items the capture produced (1 for a single
    /// add, N for a Save-all batch). Logged via the existing os_log / Sentry
    /// breadcrumb channel. Target: p90 ≤ 10,000 ms. No-op if the clock was
    /// never started (e.g. a restored batch that skipped routing).
    func logAddFlowInteractionMetric() {
        guard let start = addFlowStartedAt else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("addflow.interaction_ms=\(ms, privacy: .public) items=\(self.savedItemsFromSource, privacy: .public)")
        addFlowStartedAt = nil
    }

    /// Reset the per-capture provenance state so the next photo gets
    /// its own `source_photo_id` + a fresh save counter. Called at the
    /// top of every photo-selection / camera-capture lifecycle, BEFORE
    /// any extraction or save. Keeps the multi-garment loop scoped to
    /// one capture at a time.
    func stampFreshCapture() {
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
        // Reset the batch progress denominator + skipped counter so
        // the per-batch progress bar hides when no batch is in flight.
        batchTotalCount = 0
        batchSkippedCount = 0
        // Build 47 — a fresh capture has no confirmed category yet. The
        // multi-pick path flips this true via applyPrefill only when the
        // classifier is confident; single-item captures (no ML category)
        // leave it false so the user picks. Reset here so a prior
        // capture's confirmation doesn't leak into the next item.
        categoryConfirmed = false
        // Phase 2 — clear any prior batch's gallery overrides / shared
        // occasion so a fresh capture starts clean.
        resetFastSaveAllState()
    }

    /// User cancelled out of the camera view without capturing anything.
    /// Reset the capture method so the next interaction is fresh.
    func onCameraCancelled() {
        isShowingCamera = false
        captureMethod = .library
        // Build 6: clear a stale capture error so a transient camera-
        // init failure doesn't survive into the next open. Without
        // this, dismissing then reopening the camera leaves the
        // "Couldn't capture: …" banner sitting on the photo step.
        errorMessage = nil
    }

    /// Hook fired by `AddItemView`'s camera-cover `.onDisappear` so
    /// the VM has a single, testable seam for "user navigated away
    /// from the camera." Build 6 doesn't keep state inside the VM
    /// for the camera flow — that lives in `AddItemView.@State` —
    /// so this is intentionally a logging-only no-op today.
    ///
    /// Kept as a real entry point because:
    ///   1. Tests can spy on it without poking at view internals.
    ///   2. Future builds that move sharpness/coverage observers
    ///      back into the VM have an obvious owner for teardown.
    func onCameraCoverDismissed() {
        logger.info("camera.coverDismissed")
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


    /// Build 6 — releases heavy state held by the VM when iOS
    /// deallocates the sheet. SwiftUI tears down `@State`
    /// view models on the main actor, so `MainActor.assumeIsolated`
    /// is safe in practice; Swift 6's checker can't statically prove
    /// it, hence the dynamic assumption.
    ///
    /// We stick to direct property writes — no method calls, no
    /// `await`s, no Task spawns. The `reset()` flow handles the
    /// "user starts a new add" case; this handles the "AddItemView
    /// is torn down while still holding a big UIImage" case, which
    /// previously left those images sitting in memory until iOS
    /// reclaimed them under pressure.
    deinit {
        MainActor.assumeIsolated {
            sessionLoadTask?.cancel()
            processingTask?.cancel()
            cancellationDismissTask?.cancel()
            selectedImage = nil
            processedImage = nil
            sam2Session = nil
            proposals = nil
            pendingProposalQueue.removeAll()
            currentProposal = nil
        }
    }

    func reset() {
        currentStep = .photo
        selectedPhoto = nil
        selectedImage = nil
        processedImage = nil
        category = .top
        subcategory = .tshirt
        categoryConfirmed = false // Build 47 — clean slate; user reconfirms category on the next item
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
        isShowingPreview = false
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
        resetFastSaveAllState()
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
