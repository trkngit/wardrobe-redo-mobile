import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import os.log

extension MultiGarmentProposalService {
    // MARK: - Proposal construction

    static func makeProposal(
        from raw: RawDetection,
        sourceImage: UIImage
    ) -> MaskProposal? {
        // Composite the per-instance segmentation mask onto the source
        // image and crop to the bbox. When the mask isn't available
        // (model failure / segmentation head not decoded), this falls
        // back to a plain rect crop — still a usable image, just lacks
        // the transparent background.
        guard let cropped = compositeMaskedItem(
            sourceImage: sourceImage,
            mask: raw.mask,
            bbox: raw.boundingBox,
            secondaryMask: raw.secondaryMask
        ) else {
            staticLogger.notice("makeProposal.dropped reason=cropFailed rawClass=\(raw.rawClass, privacy: .public)")
            return nil
        }
        let category = ClothingCategory.fromFashionpediaClass(raw.rawClass)
        let subcategory = ClothingSubcategory.fromFashionpediaClass(raw.rawClass)
        let confidence: ExtractionConfidence = {
            if raw.score >= 0.85 { return .high }
            if raw.score >= 0.6 { return .medium }
            return .low
        }()
        // Per-proposal telemetry — dogfood failures (sneakers→Boots,
        // sunglasses→Hat, etc.) need the raw model class string + the
        // resolved category/subcategory side-by-side to triage. PII-
        // safe: bbox geometry only, no image bytes or user identifiers.
        staticLogger.info(
            """
            makeProposal: \
            rawClass=\(raw.rawClass, privacy: .public) \
            score=\(raw.score, privacy: .public) \
            bbox=(\(raw.boundingBox.minX, privacy: .public),\(raw.boundingBox.minY, privacy: .public),\(raw.boundingBox.width, privacy: .public),\(raw.boundingBox.height, privacy: .public)) \
            category=\(category?.rawValue ?? "nil", privacy: .public) \
            subcategory=\(subcategory?.rawValue ?? "nil", privacy: .public) \
            hasMask=\(raw.mask != nil, privacy: .public)
            """
        )
        return MaskProposal(
            id: UUID(),
            maskedImage: cropped,
            mask: raw.mask,
            confidence: confidence,
            predictedCategory: category,
            // raw.score is already a post-sigmoid objectness in [0,1];
            // DETR's formulation makes "is this a valid detection of
            // class C" inseparable from "what's the class C", so the
            // detection score IS the category confidence.
            predictedCategoryConfidence: raw.score,
            predictedSubcategory: subcategory,
            boundingBox: raw.boundingBox,
            detectionScore: raw.score,
            modelClassRaw: raw.rawClass
        )
    }

    /// Run the attribute classifier on a proposal's cropped image and
    /// feed the result through the rules engine to populate seasons +
    /// occasions. Classifier errors (model missing, inference threw)
    /// are swallowed — the proposal is returned with rules-engine-only
    /// fallback so the caller's UX is identical to the "no classifier
    /// injected" path.
    static func enriched(
        _ proposal: MaskProposal,
        with classifier: AttributeClassifying,
        logger: Logger
    ) async -> MaskProposal {
        let prediction: AttributePrediction
        do {
            prediction = try await classifier.predict(crop: proposal.maskedImage)
        } catch {
            logger.notice("attribute.predict.failed \(error.localizedDescription, privacy: .public)")
            return enrichedWithRulesOnly(proposal, logger: logger)
        }
        return applyAttributesAndRules(
            to: proposal,
            prediction: prediction,
            pathTaken: "ml-classifier",
            logger: logger
        )
    }

    /// Fallback enrichment when no classifier is available. Still
    /// populates seasons + occasions from the rules engine using
    /// whatever category + subcategory the detection head produced.
    static func enrichedWithRulesOnly(
        _ proposal: MaskProposal,
        logger: Logger? = nil
    ) -> MaskProposal {
        applyAttributesAndRules(
            to: proposal,
            prediction: .empty,
            pathTaken: "rules-only",
            logger: logger
        )
    }

    /// Shared enrichment logic: given a base proposal and an (optional)
    /// attribute prediction, return a proposal with seasons + occasions
    /// filled in from `AttributeRulesEngine`.
    ///
    /// The `pathTaken` parameter exists purely for diagnostics — it
    /// distinguishes the `ml-classifier` (attribute model returned a
    /// prediction), `rules-only` (no classifier or classifier errored),
    /// and `direct` (callers like tests bypass the higher-level
    /// orchestration) paths in the structured log line emitted at the
    /// end of this method. Build-5 dogfood (PR #25) added the log so
    /// future "texture not pre-filled" failures can be diagnosed by
    /// grep'ing the device log for `multiGarment.enrichment` rather
    /// than re-instrumenting the codebase.
    static func applyAttributesAndRules(
        to proposal: MaskProposal,
        prediction: AttributePrediction,
        pathTaken: String = "direct",
        logger: Logger? = nil
    ) -> MaskProposal {
        // Rules engine needs a concrete ClothingCategory +
        // ClothingSubcategory. Fall back to sensible defaults when the
        // detection head didn't surface one — the enum's `.category`
        // chain keeps the types consistent, and every subcategory has
        // a category by construction.
        let category = proposal.predictedCategory
            ?? proposal.predictedSubcategory?.category
            ?? .top
        let subcategory = proposal.predictedSubcategory
            ?? ClothingSubcategory.subcategories(for: category).first
            ?? .tshirt

        // Texture: prefer the ML prediction when present. When the
        // Build 6: texture is exclusively rules-derived. The
        // deterministic subcategory→texture lookup (jeans → denim,
        // sweater → knit, …) is the only auto-population path; ML
        // inference for texture was retired (`AttributePrediction`
        // no longer carries a texture field). Rules-derived textures
        // stamp a 0.85 confidence sentinel — just above the 0.80
        // prefill gate in `AttributePrefill` — so they pass the gate
        // while staying distinguishable from user-confirmed values in
        // the `detected_attributes` JSONB telemetry.
        let resolvedTexture: TextureType?
        let resolvedTextureConfidence: Float
        let textureSource: String
        if let rulesTexture = AttributeRulesEngine.deriveTexture(
            category: category, subcategory: subcategory
        ) {
            resolvedTexture = rulesTexture
            resolvedTextureConfidence = AttributeRulesEngine.rulesTextureConfidence
            textureSource = "rules-table"
        } else {
            resolvedTexture = nil
            resolvedTextureConfidence = 0.0
            textureSource = "none"
        }

        let rules = AttributeRulesEngine.derive(
            category: category,
            subcategory: subcategory,
            texture: resolvedTexture
        )

        // Build-5 dogfood (PR #25): structured log so future "texture
        // not pre-filled" failures can be diagnosed by tailing the
        // device log for `multiGarment.enrichment`. Captures the path
        // taken (ml-classifier / rules-only / direct), the resolved
        // category + subcategory the rules engine used, the resolved
        // texture, and which lookup tier produced it (prediction /
        // rules-table / none). The log is gated on a Logger being
        // injected so tests calling this static directly don't spam.
        if let logger {
            let categoryRaw = category.rawValue
            let subcategoryRaw = subcategory.rawValue
            let textureRaw = resolvedTexture?.rawValue ?? "nil"
            logger.info("multiGarment.enrichment: path=\(pathTaken, privacy: .public) category=\(categoryRaw, privacy: .public) subcategory=\(subcategoryRaw, privacy: .public) texture=\(textureRaw, privacy: .public) source=\(textureSource, privacy: .public)")
        }

        return MaskProposal(
            id: proposal.id,
            maskedImage: proposal.maskedImage,
            mask: proposal.mask,
            confidence: proposal.confidence,
            predictedCategory: proposal.predictedCategory,
            predictedCategoryConfidence: proposal.predictedCategoryConfidence,
            predictedSubcategory: proposal.predictedSubcategory,
            predictedTexture: resolvedTexture,
            predictedTextureConfidence: resolvedTextureConfidence,
            predictedFit: prediction.fit,
            predictedFitConfidence: prediction.fitConfidence,
            predictedSeasons: Array(rules.seasons).sorted { $0.rawValue < $1.rawValue },
            predictedOccasions: Array(rules.occasions).sorted { $0.rawValue < $1.rawValue },
            boundingBox: proposal.boundingBox,
            detectionScore: proposal.detectionScore,
            modelClassRaw: proposal.modelClassRaw
        )
    }

    // MARK: - Working-image downscale

    /// Returns a downscaled copy of `image` whose longest side is at
    /// most `workingImageMaxDimension` px. Returns the input unchanged
    /// when it's already small enough — no allocation, no work.
    ///
    /// Render scale is forced to 1 so the resulting bitmap memory is
    /// exactly `width × height × 4` bytes; a `UIImage` constructed at
    /// the device's native scale would silently use 4-9× more RAM
    /// because the renderer would multiply the pixel count by
    /// `UIScreen.main.scale²`.
    ///
    /// `static` so unit tests can verify the resize behaviour without
    /// instantiating the service or hitting the model bundle.
    static func downscaledForCutouts(_ image: UIImage) -> UIImage {
        let maxDim = max(image.size.width, image.size.height)
        guard maxDim > workingImageMaxDimension else { return image }

        let scale = workingImageMaxDimension / maxDim
        let target = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )
        guard target.width > 0, target.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Composite the per-instance segmentation mask onto the source image
    /// then crop to the proposal's bounding box, producing a transparent-
    /// background `UIImage`.
    ///
    /// **Why this exists.** The previous `cropped()` took a rectangular
    /// slice of the source photo. Wardrobe cards rendered those slices
    /// with the source-photo backdrop visible (the "mirror selfie behind
    /// the shirt" bug). RFDETR-Seg already produces a per-instance
    /// segmentation mask — this function uses it to mask out everything
    /// outside the garment, leaving alpha=0 outside and ~alpha=255 inside.
    ///
    /// **Mask handling.**
    ///   * `mask == nil` → fall back to a plain rectangular bbox crop
    ///     (back-compat with the legacy `cropped()` behavior). The model
    ///     can fail to surface a mask (e.g. when the segmentation head
    ///     isn't decoded yet) and we'd rather show a rect crop than
    ///     drop the proposal entirely.
    ///   * `mask != nil` → run `MaskCleaner.clean` to drop the soft
    ///     fringe, scale to source extent, composite via `CIBlendWithMask`
    ///     against transparency, then crop to the bbox region.
    ///
    /// The masking approach uses `CIBlendWithMask` — same pattern as
    /// `VisionForegroundExtractor.applyMask` (the single-item flow). See
    /// `web-research/G-ios-isolation-best-practices.md` § 2.1 for rationale.
    static func compositeMaskedItem(
        sourceImage: UIImage,
        mask: CVPixelBuffer?,
        bbox normalizedBox: CGRect,
        secondaryMask: CVPixelBuffer? = nil
    ) -> UIImage? {
        guard let cg = sourceImage.cgImage else { return sourceImage }

        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(
            x: normalizedBox.minX * w,
            y: normalizedBox.minY * h,
            width: normalizedBox.width * w,
            height: normalizedBox.height * h
        ).integral

        // No usable mask — preserve the legacy rect-crop behavior so the
        // proposal still surfaces (better than dropping it entirely).
        guard let mask else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }

        // Composite source over transparent background using the cleaned
        // mask. CIImage extents put origin at bottom-left while CGImage
        // pixels are top-left — both extents are full-image so the
        // bbox-pixel rect we computed above is in the right space for
        // the final cgImage crop.
        let sourceCI = CIImage(cgImage: cg)
        let maskCI = CIImage(cvPixelBuffer: mask)

        // Scale mask to match source extent (RFDETR's mask is at model
        // resolution, e.g. 320×320; source can be 1280×… after the
        // working-image downscale).
        let sx = sourceCI.extent.width / max(maskCI.extent.width, 1)
        let sy = sourceCI.extent.height / max(maskCI.extent.height, 1)
        var scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // Build 47 — shoe-pair union. When a second instance mask is
        // present (a fused left+right shoe pair), scale it to source
        // extent the same way and OR the two alpha masks via
        // CIMaximumCompositing so the resulting cutout contains BOTH
        // shoes. Per-foot masks don't overlap, so max == union here.
        if let secondaryMask {
            let secondaryCI = CIImage(cvPixelBuffer: secondaryMask)
            let ssx = sourceCI.extent.width / max(secondaryCI.extent.width, 1)
            let ssy = sourceCI.extent.height / max(secondaryCI.extent.height, 1)
            let scaledSecondary = secondaryCI.transformed(by: CGAffineTransform(scaleX: ssx, y: ssy))
            if let union = CIFilter(name: "CIMaximumCompositing") {
                union.setValue(scaledMask, forKey: kCIInputImageKey)
                union.setValue(scaledSecondary, forKey: kCIInputBackgroundImageKey)
                if let combined = union.outputImage {
                    scaledMask = combined
                }
            }
        }

        // Drop the soft fringe. If cleaning fails for any reason, fall
        // back to the un-cleaned scaled mask rather than the rect crop —
        // a slightly fringy cutout still beats a rect crop visually.
        let finalMask = MaskCleaner.clean(scaledMask) ?? scaledMask

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }
        blend.setValue(sourceCI, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(finalMask, forKey: kCIInputMaskImageKey)

        guard let composited = blend.outputImage else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }

        let context = CIContext(options: nil)
        guard let fullCG = context.createCGImage(composited, from: sourceCI.extent) else {
            return rectCropFallback(cg, rect: rect, base: sourceImage)
        }

        // Crop the composited image to the bbox region. fullCG carries
        // alpha now, so the crop preserves transparency outside the
        // garment silhouette.
        guard rect.width > 1, rect.height > 1,
              let cropped = fullCG.cropping(to: rect) else {
            return UIImage(cgImage: fullCG, scale: sourceImage.scale, orientation: sourceImage.imageOrientation)
        }
        return UIImage(cgImage: cropped, scale: sourceImage.scale, orientation: sourceImage.imageOrientation)
    }

    /// Rectangular bbox crop — the legacy behavior preserved as the
    /// nil-mask fallback so any caller that hits the no-mask path still
    /// gets a usable image. Kept private since callers should always go
    /// through `compositeMaskedItem`.
    private static func rectCropFallback(_ cg: CGImage, rect: CGRect, base: UIImage) -> UIImage? {
        guard rect.width > 1, rect.height > 1,
              let cropped = cg.cropping(to: rect) else { return base }
        return UIImage(cgImage: cropped, scale: base.scale, orientation: base.imageOrientation)
    }
}
