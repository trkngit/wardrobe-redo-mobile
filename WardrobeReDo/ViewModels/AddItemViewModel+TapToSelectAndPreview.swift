import Foundation
import Observation
import os
import UIKit
import PhotosUI
import SwiftUI

extension AddItemViewModel {
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

    // MARK: - Build 45 — Preview & Confirm handlers

    /// User tapped "Use this" on the Preview & Confirm screen. The
    /// auto-extraction's mask was good enough; commit it and route
    /// straight to the details step. No re-encoding needed (the mask
    /// already lives in `processedImage.maskedData` from the auto
    /// pipeline).
    func onPreviewConfirmed() {
        logger.info("preview.action action=confirmed method=\(self.processedImage?.extractionMethod?.rawValue ?? "nil", privacy: .public)")
        isShowingPreview = false
        currentStep = .details
    }

    /// User tapped "Refine if needed" on the Preview & Confirm screen.
    /// Hand off to the existing tap-to-select flow with the auto mask
    /// pre-populated — the cached SAM2 session (loaded in
    /// `applyProcessedFrom{Library,Camera}`) is still alive so the
    /// first tap is cheap.
    func onPreviewRefine() {
        logger.info("preview.action action=refined method=\(self.processedImage?.extractionMethod?.rawValue ?? "nil", privacy: .public)")
        isShowingPreview = false
        isShowingTapToSelect = true
    }

    /// User tapped "Retake" on the Preview & Confirm screen. Drop back
    /// to the photo step so they can pick a different source.
    func onPreviewRetake() {
        logger.info("preview.action action=retook method=\(self.processedImage?.extractionMethod?.rawValue ?? "nil", privacy: .public)")
        isShowingPreview = false
        currentStep = .photo
        // Drop the bad processed image so the next photo gets a fresh
        // analyze cycle instead of inheriting this one's mask.
        processedImage = nil
        sam2Session = nil
    }

}
