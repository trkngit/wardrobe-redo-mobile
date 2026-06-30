import Foundation
import Observation
import os
import UIKit
import PhotosUI
import SwiftUI

extension AddItemViewModel {
    // MARK: - Phase 5 multi-garment multi-pick

    /// User tapped "Save N items" on `MultiGarmentGridView`. Takes
    /// the current checkbox selection, orders it score-descending so the
    /// most confident garment is detailed first (matching the display
    /// order), and starts the sequential details loop.
    ///
    /// Async because `startNextProposal` now awaits per-proposal color
    /// extraction so each item shows its own palette in the details
    /// step. SwiftUI buttons wrap the call in `Task { ... }`.
    func onMultiPickConfirmed() async {
        guard let proposals else { return }
        pendingProposalQueue = proposals
            .filter { selectedProposalIDs.contains($0.id) }
            .sorted { $0.detectionScore > $1.detectionScore }
        // Stamp the batch denominator so the progress bar in
        // `AddItemView` knows how many items the user committed to.
        // Stays stable across the queue iteration; reset to 0 only
        // when the batch ends (all-saved, all-skipped, or cancelled).
        batchTotalCount = pendingProposalQueue.count
        batchSkippedCount = 0
        logger.info("multiGarment.confirm: \(self.pendingProposalQueue.count) items queued")
        // `startNextProposal` calls `persistBatchSnapshot()` itself,
        // so a force-quit between confirm and the first save still
        // preserves the queue. See `BatchPersistenceService`.
        await startNextProposal()
    }

    /// Phase 2 — the approval-gallery "Save all N" path. Same queue seed as
    /// `onMultiPickConfirmed`, but flips `isFastSaveAll` so the shared
    /// `startNextProposal` loop commits each item via `save()` WITHOUT the
    /// per-item Fast Confirm card stop. The whole selected batch saves in
    /// one pass; source-photo upload dedup, idempotency, per-item formality
    /// (1B) and the progress bar are all reused unchanged. A mid-batch save
    /// failure halts the loop on `.details` for the failed item (save()'s
    /// success branch is the only thing that pops the next proposal).
    func onSaveAllConfirmed(userId: UUID) async {
        guard let proposals else { return }
        pendingProposalQueue = proposals
            .filter { selectedProposalIDs.contains($0.id) }
            .sorted { $0.detectionScore > $1.detectionScore }
        guard !pendingProposalQueue.isEmpty else { return }
        batchTotalCount = pendingProposalQueue.count
        batchSkippedCount = 0
        isFastSaveAll = true
        fastSaveUserId = userId
        logger.info("multiGarment.saveAll: \(self.pendingProposalQueue.count) items queued (fast-save)")
        await startNextProposal()
    }

    /// Clear all Phase 2 Save-all state. Called wherever a batch ends or a
    /// fresh capture begins so a stale override/occasion can't leak into the
    /// next batch. The occasion resets to the single-item default.
    func resetFastSaveAllState() {
        isFastSaveAll = false
        fastSaveUserId = nil
        proposalCategoryOverrides = [:]
        sharedBatchOccasions = [.casual]
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
        resetFastSaveAllState()
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
        batchTotalCount = 0
        batchSkippedCount = 0
        // Discard any persisted batch — user explicitly bailed.
        BatchPersistenceService.clear()
        resetFastSaveAllState()
        currentStep = .photo
    }

    /// "Skip this item" toolbar action on the details step, visible only
    /// while a batch is in flight (`currentProposal != nil`). Pops the
    /// next proposal without saving the current one; if the queue is
    /// empty this becomes a no-save finish like the user just tapped
    /// Cancel on the last item.
    ///
    /// Async because `startNextProposal` now awaits per-proposal color
    /// extraction so the next item's palette is ready by the time the
    /// user lands on its details form. SwiftUI toolbar wraps in `Task`.
    func onSkipCurrentProposal() async {
        // Bump the skipped counter so the progress bar advances even
        // for items the user opts out of. (Saved items advance the bar
        // via `savedItemsFromSource` in `save(userId:)`.)
        batchSkippedCount += 1
        logger.info("multiGarment.skip: skipping current proposal, \(self.pendingProposalQueue.count) remaining")
        // `startNextProposal` re-persists or clears the snapshot
        // based on whether the queue still has items.
        await startNextProposal()
    }

    /// Pop the next proposal off the queue and prepare the details step
    /// for it. Swaps the proposal's cutout into `processedImage` so the
    /// details preview shows the correct garment, resets item-specific
    /// metadata to defaults, and lowers the multi-pick cover.
    ///
    /// When the queue is empty this routes to one of:
    /// - `didSave = true` if at least one item was saved (batch done)
    /// - `.photo` step if nothing was saved (user skipped all)
    ///
    /// Async because color extraction now runs per-proposal (see
    /// `extractColors` await below) — earlier the constructor inherited
    /// the source-photo palette from `current.dominantColors`, which
    /// meant items 2..N of a multi-pick batch all showed item 1's
    /// colors. The await is constant-time on small mask cutouts (k-means
    /// clusters at 50×50) and gates the UI flip into `.details`, which
    /// already represents tens of milliseconds of processing.
    private func startNextProposal() async {
        guard !pendingProposalQueue.isEmpty else {
            isShowingMultiPick = false
            isShowingTapToSelect = false
            currentProposal = nil
            // End-of-queue: clear the persisted batch since it's
            // either fully consumed (every item saved or skipped) or
            // the user is bouncing back to the photo step.
            BatchPersistenceService.clear()
            resetFastSaveAllState()
            if savedItemsFromSource > 0 {
                // At least one garment landed — treat the batch as done
                // and dismiss the sheet like any normal save flow.
                logAddFlowInteractionMetric()
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
        // Persist the new queue position to disk so a crash or
        // jetsam between here and the next user action loses at most
        // one item of work.
        persistBatchSnapshot()
        // Splice the proposal's cutout into processedImage so the
        // details preview renders the right garment. PNG preserves the
        // transparent background — JPEG would flatten it.
        if let current = processedImage {
            // Re-extract dominant colors from THIS proposal's cutout
            // before reconstructing `processedImage`. Without this the
            // new ProcessedImage inherits `current.dominantColors`
            // (which were extracted once from the source photo on the
            // initial `processImage(_:)` call) — every item in a
            // multi-pick batch then surfaces the same palette. Falls
            // back to the source-photo palette only when CGImage
            // conversion fails, since `extractColors` already returns
            // an empty array on broken inputs.
            let perProposalColors: [ExtractedColor]
            if next.maskedImage.cgImage != nil {
                perProposalColors = await colorExtractor.extractColors(from: next.maskedImage)
            } else {
                perProposalColors = current.dominantColors
            }

            processedImage = ProcessedImage(
                originalData: current.originalData,
                thumbnailData: current.thumbnailData,
                maskedData: next.maskedImage.pngData(),
                extractionConfidence: next.confidence,
                extractionMethod: .multiGarmentRFDETR,
                dominantColors: perProposalColors,
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

        // Phase 2 — apply the user's gallery choices ON TOP of applyPrefill's
        // ML seed so they win: a per-card category correction (clamped into a
        // valid subcategory via onCategoryChanged) and, on the Save-all path,
        // the one shared batch occasion.
        if let override = proposalCategoryOverrides[next.id] {
            category = override
            categoryConfirmed = true
            onCategoryChanged()
        }
        if isFastSaveAll {
            if !sharedBatchOccasions.isEmpty {
                selectedOccasions = sharedBatchOccasions
            }
            // Commit this item with its auto attributes; save()'s success
            // branch pops the next proposal, so the whole selected batch
            // saves in one pass with no per-item form stop. A save FAILURE
            // sets currentStep = .details and does NOT recurse, halting the
            // loop on the failed item for the user to retry.
            if let uid = fastSaveUserId {
                await save(userId: uid)
            } else {
                currentStep = .details
            }
        } else {
            currentStep = .details
        }
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
    func applyPrefill(from proposal: MaskProposal) {
        guard FeatureFlags.isAttributeDetectionEnabled else {
            // Legacy behaviour: reset every picker to its hard-coded
            // default. Matches the pre-Phase-0 `startNextProposal` logic.
            //
            // Build-5 dogfood (PR #25) added this log so a remotely
            // disabled flag is visible in the device log — without it
            // a "texture / subcategory / seasons not pre-filled" report
            // is indistinguishable from a rules-engine failure.
            logger.notice("applyPrefill.skipped: FeatureFlags.isAttributeDetectionEnabled=false — falling back to legacy hard-reset")
            category = .top
            subcategory = .tshirt
            texture = nil
            fitAttribute = nil
            selectedSeasons = Set(Season.allCases)
            selectedOccasions = [.casual]
            detectedAttributes = [:]
            // Flag-off is a classifier kill-switch; preserve the legacy
            // "saveable with defaults" behaviour so disabling the model
            // remotely doesn't strand users on an unconfirmed category.
            categoryConfirmed = true
            return
        }

        var snapshot: [String: String] = [:]

        // Build 47 — CATEGORY is gated STRICTLY via `confidentCategory`
        // (the SAME gate the multi-pick grid uses, so the grid label and
        // the details category can never disagree — the "shoe became a
        // t-shirt between screens" report). When the classifier isn't
        // confident, category/subcategory are NOT auto-assigned and the
        // user must pick (`categoryConfirmed = false` gates Save + drives
        // the "Choose a category" prompt). texture / fit / seasons /
        // occasions below keep their OWN independent per-field gates, so
        // a separately-confident signal still pre-fills even when the
        // category itself was uncertain.
        // Build 52 — Fast Add commits the model's TOP category guess
        // regardless of confidence (the user corrects it in one tap on the
        // Fast Confirm card, and `canSave` no longer requires confirmation).
        // When Fast Add is off, fall back to the TF47 strict gate via
        // `confidentCategory`, which leaves the category UNSET below 0.90 so
        // the user must pick. Either way the committed value is snapshotted
        // for provenance.
        let confident: ClothingCategory?
        if FeatureFlags.isFastAddEnabled {
            confident = proposal.predictedCategory
            categoryConfirmed = true
        } else {
            confident = proposal.confidentCategory
            categoryConfirmed = (confident != nil)
        }
        category = confident ?? .top  // .top is an internal placeholder; UI shows the prompt when unconfirmed
        if let confident { snapshot["category"] = confident.rawValue }

        if categoryConfirmed {
        // Subcategory prediction is already a conservative commit (nil
        // for ambiguous Fashionpedia classes, see
        // `ClothingSubcategory.fromFashionpediaClass`), so it doesn't
        // have its own confidence field. Guard on `category` match so a
        // prediction mismatch (e.g. predicted blazer→.suitJacket but
        // category fell back to .top) doesn't leave the picker stuck on
        // an invalid option.
        //
        // Build 5 inversion: for `.accessory` and `.shoe` specifically,
        // the raw-class rescue runs FIRST. The previous ordering let a
        // generic `predictedSubcategory` (e.g. `.hat` from
        // `fromFashionpediaClass("glasses")` returning `.sunglasses` but
        // a downstream prediction landing on `.hat`, or the model's
        // default `.boots` for any shoe) override the rescue and silently
        // mis-prefill multi-pick items. The rescue mapping is the
        // authoritative bridge between the trained vocabulary and our
        // enum, so it should win whenever it has an opinion. Other
        // categories keep the original ordering — their predicted
        // subcategories already line up with our enum without rescue.
        // See `ClothingSubcategory.accessorySubcategoryFromRawClass` and
        // `ClothingSubcategory.shoeSubcategoryFromRawClass`.
        //
        // Subcategory branch telemetry (`subcategoryBranch`) tags which
        // path resolved the subcategory so dogfood can separate "model
        // got it right" from "rescue fired" from "category default"
        // from "user fixed it later". PII-safe: raw class + category
        // enum only.
        let subcategoryBranch: String
        if category == .accessory {
            if let rescue = ClothingSubcategory.accessorySubcategoryFromRawClass(proposal.modelClassRaw) {
                subcategory = rescue
                snapshot["subcategory"] = rescue.rawValue
                subcategoryBranch = "accessoryRescue"
            } else if let sub = proposal.predictedSubcategory, sub.category == category {
                subcategory = sub
                snapshot["subcategory"] = sub.rawValue
                subcategoryBranch = "accessoryPredicted"
            } else {
                // Build 6: rescue + predictedSubcategory both punted —
                // model is emitting an unmapped accessory class
                // (`headband`, `tie`, `glove`, etc., per build-5 dogfood).
                // Use bbox y-position to infer sunglasses (face area)
                // vs belt (waist) vs default `.hat`. Pure function on
                // CGRect so the heuristic is easy to test + tune.
                //
                // Heuristic-derived subcategories are intentionally NOT
                // recorded in `snapshot` — they're not ML-driven, just
                // geometric defaults. Matches the categoryDefault path
                // for telemetry purposes.
                subcategory = ClothingSubcategory.accessorySubcategoryFromBboxHeuristic(proposal.boundingBox)
                subcategoryBranch = "accessoryBboxHeuristic"
            }
        } else if category == .shoe {
            if let rescue = ClothingSubcategory.shoeSubcategoryFromRawClass(proposal.modelClassRaw) {
                subcategory = rescue
                snapshot["subcategory"] = rescue.rawValue
                subcategoryBranch = "shoeRescue"
            } else if let sub = proposal.predictedSubcategory, sub.category == category {
                subcategory = sub
                snapshot["subcategory"] = sub.rawValue
                subcategoryBranch = "shoePredicted"
            } else {
                subcategory = defaultSubcategory(for: category)
                subcategoryBranch = "shoeDefault"
            }
        } else {
            // Tops, bottoms, dresses, outerwear: trust the predicted
            // subcategory when it lines up with the category, else fall
            // back to the category default.
            if let sub = proposal.predictedSubcategory, sub.category == category {
                subcategory = sub
                snapshot["subcategory"] = sub.rawValue
                subcategoryBranch = "predicted"
            } else {
                subcategory = defaultSubcategory(for: category)
                subcategoryBranch = "categoryDefault"
            }
        }
        logger.info(
            "applyPrefill.subcategory branch=\(subcategoryBranch, privacy: .public) rawClass=\(proposal.modelClassRaw, privacy: .public) category=\(self.category.rawValue, privacy: .public) subcategory=\(self.subcategory.rawValue, privacy: .public)"
        )
        } else {
            // Build 47 — unconfident category: neutral subcategory
            // placeholder, not stamped as ML-detected. `onCategoryChanged`
            // re-clamps it into the valid set when the user picks.
            subcategory = .tshirt
            logger.info("applyPrefill.unconfident: category/subcategory not auto-assigned (categoryConfidence=\(proposal.predictedCategoryConfidence, privacy: .public), rawClass=\(proposal.modelClassRaw, privacy: .public)) — user must choose")
        }

        if let tex = proposal.predictedTexture,
           FeatureFlags.isFastAddEnabled || AttributePrefill.shouldPrefill(proposal.predictedTextureConfidence) {
            texture = tex
            snapshot["texture"] = tex.rawValue
            // Build 6: texture is exclusively rules-derived (ML
            // inference for texture was retired — see
            // `AttributeClassifierService` docstring). The source tag
            // stays in telemetry so historical rows remain comparable;
            // every new row stamps `"rules"`.
            snapshot["texture_source"] = "rules"
        } else {
            texture = nil
        }

        if let fit = proposal.predictedFit,
           FeatureFlags.isFastAddEnabled || AttributePrefill.shouldPrefill(proposal.predictedFitConfidence) {
            fitAttribute = fit
            snapshot["fit"] = fit.rawValue
        } else if FeatureFlags.isFastAddEnabled {
            // Build 52 — default to a neutral fit (not nil) so
            // ProportionBalance keeps full coverage instead of dropping the
            // dimension. Not snapshotted as ML-detected: it's a default, and
            // low-confidence fit becomes a later enrichment prompt.
            fitAttribute = .regular
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

        // TF52 — compute effective formality once, on the app's canonical
        // [0,1] scale, and persist it so `FormalityCoherenceScorer` trusts
        // it at full coverage instead of recomputing. `FormalityFormula`
        // is the single source of truth shared by the scorer and the add
        // flow, so the stored value can never drift from how it's scored.
        let formality = FormalityFormula.compute(
            category: category,
            texture: texture,
            dominantColors: colors,
            fitAttribute: fitAttribute
        )
        let formalityValue = formality.value
        let formalityComponents = formality.components

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
        // Capture the proposal's normalized bbox once so the detached
        // upload Task doesn't need to read MainActor state. Multi-pick
        // garments carry a non-nil `currentProposal`; single-photo
        // captures end up with `currentProposal == nil` and stamp a
        // nil bbox — matches the "no bbox was ever computed" semantics
        // baked into `BoundingBoxCodable?` on `wardrobe_items` (see
        // migration 00013).
        let capturedBoundingBox = currentProposal.map { BoundingBoxCodable($0.boundingBox) }

        logger.info("save: starting upload for itemId=\(itemId) sourcePhotoId=\(capturedSourcePhotoId?.uuidString ?? "nil") savedSoFar=\(self.savedItemsFromSource)")

        // Build 40 — payload-size + heap baseline before kicking off
        // the 4-file Supabase upload. Pairs with `upload.{file}.start`
        // breadcrumbs in ImageService so post-ship analysis can
        // correlate huge originals with timeouts or memory pressure.
        logger.info("save.payload.sizes original=\(processed.originalData.count, privacy: .public) thumb=\(processed.thumbnailData.count, privacy: .public) masked=\(processed.maskedData?.count ?? 0, privacy: .public) mem=\(MemoryMonitor.currentHeapUsageMB, privacy: .public)")

        let extractionConfidenceRaw = processed.extractionConfidence?.rawValue

        // Race the entire save operation against a 45-second timeout.
        // The tuple carries (success, resolvedSourcePhotoPath) so the
        // main-actor branch below can persist the source path back onto
        // the ViewModel for garments 2..N to reuse.
        let outcome: (success: Bool, sourcePath: String?) = await withTaskGroup(
            of: (Bool, String?).self
        ) { group in
            group.addTask { [imageService, wardrobeRepository, uploadQueue, logger] in
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
                        detectedAttributes: provenance,
                        // Client-generated key for dedup on retry.
                        // See migration 00010 + insertItem doc comment.
                        idempotencyKey: UUID(),
                        // Persist the multi-pick proposal's normalized
                        // bbox so the item detail view can dim every-
                        // thing outside this garment's rect when
                        // rendering the source photo. Nil for single-
                        // item captures (no proposal was ever computed).
                        boundingBox: capturedBoundingBox,
                        // Build 6 Phase 8B — persist mask coverage so
                        // `ColorHarmonyScorer` can modulate the
                        // category-default silhouette weight by
                        // actual visual mass. Nil on extraction
                        // failure; the scorer falls back to the
                        // category default alone.
                        silhouetteArea: processed.silhouetteArea,
                        // TF52 — persist client-computed formality so the
                        // scorer trusts it at full coverage. Migration
                        // 00018 retires the DB's 0–10 compute trigger so
                        // these [0,1] values aren't overwritten server-side.
                        formalityComputed: formalityValue,
                        formalityComponents: formalityComponents
                    )

                    // Primary path: hit the repo synchronously so the UX
                    // contract (spinner → saved confirmation) stays the
                    // same. The repo already wraps `withRetry`, so by the
                    // time this throws the in-process retry budget is
                    // exhausted. If the error is still retryable (e.g.
                    // the phone came back online after we gave up, or a
                    // 503 that might clear by morning), persist the
                    // insert via UploadQueue so a later drain on next
                    // foreground / cold start can replay it. The queue's
                    // envelope payload is the same `NewWardrobeItem` DTO
                    // with the same `idempotencyKey`, so a delayed
                    // replay resolves naturally if the first attempt
                    // actually landed but we lost the ack.
                    do {
                        _ = try await wardrobeRepository.insertItem(newItem)
                        logger.info("save: insert complete")
                        return (true, paths.sourcePhotoPath)
                    } catch let error where isRetryableError(error) {
                        logger.warning("save: retryable insert failure, enqueueing for background retry: \(error.localizedDescription)")
                        try await uploadQueue.enqueue(.wardrobeItem, payload: newItem)
                        logger.info("save: enqueued for background retry")
                        return (true, paths.sourcePhotoPath)
                    }
                    // Non-retryable insert errors (auth / 4xx / cancellation)
                    // fall through to the outer catch and hit the
                    // existing orphan-cleanup + user-visible error path.
                } catch {
                    logger.error("save: failed — \(error.localizedDescription)")
                    // Build 40 — surface the failure to Sentry so a
                    // user-visible "save failed" banner produces a
                    // dashboard event. Previously only true crashes
                    // were captured; recoverable failures hid from
                    // the dashboard, making remote diagnosis hard.
                    SentryService.captureNonFatal(error, category: "save")

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
                await startNextProposal()
            } else if shouldLoopAfter {
                // "Save & add another garment" path: keep the captured
                // image + session hot, clear only item-specific metadata,
                // and re-enter tap-to-select for the next garment.
                resetKeepingSource()
                isShowingTapToSelect = true
            } else {
                logAddFlowInteractionMetric()
                didSave = true
            }
        } else {
            errorMessage = String(localized: "Failed to save item. Check your connection and try again.")
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
        // Build 47 — next garment in the "Save & add another" loop is a
        // fresh item; require an explicit category choice for it too.
        categoryConfirmed = false
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
}
