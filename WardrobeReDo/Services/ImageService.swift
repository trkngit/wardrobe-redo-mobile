import UIKit
import PhotosUI
import SwiftUI
import Supabase
import os.log

struct ProcessedImage: Sendable {
    let originalData: Data
    let thumbnailData: Data
    /// Background-masked version as PNG (preserves alpha). Nil when
    /// extraction failed — the UI falls back to `originalData` and the
    /// row is treated as "legacy unmasked."
    let maskedData: Data?
    /// Synthetic confidence bucket for the extraction attempt. Nil
    /// when extraction was skipped (e.g. simulator build).
    let extractionConfidence: ExtractionConfidence?
    /// Which pipeline stage produced the final mask. Drives UI affordances
    /// (e.g. the "auto-cropped" badge in `MaskTouchupView`) and is logged
    /// for benchmarking. Nil when extraction was skipped.
    let extractionMethod: ExtractionMethod?
    let dominantColors: [ExtractedColor]
    /// Multi-garment proposals detected in this photo, if the
    /// `FeatureFlags.isMultiGarmentEnabled` gate was on and the Core ML
    /// model produced any. Nil → detection skipped or failed; `count <=
    /// 1` → downstream `AddItemViewModel` falls through to the existing
    /// single-item `TapToSelectView`. `count >= 2` → present the
    /// `MultiGarmentGridView` and queue per-item details.
    let proposals: [MaskProposal]?
    /// Build 6 Phase 8B — fraction of the source frame the
    /// extracted mask covers, in [0, 1]. Sourced from
    /// `ExtractionResult.silhouetteArea`. Nil when extraction was
    /// skipped or failed outright.
    let silhouetteArea: Double?

    init(
        originalData: Data,
        thumbnailData: Data,
        maskedData: Data?,
        extractionConfidence: ExtractionConfidence?,
        extractionMethod: ExtractionMethod?,
        dominantColors: [ExtractedColor],
        proposals: [MaskProposal]? = nil,
        silhouetteArea: Double? = nil
    ) {
        self.originalData = originalData
        self.thumbnailData = thumbnailData
        self.maskedData = maskedData
        self.extractionConfidence = extractionConfidence
        self.extractionMethod = extractionMethod
        self.dominantColors = dominantColors
        self.proposals = proposals
        self.silhouetteArea = silhouetteArea
    }
}

@MainActor
final class ImageService: ImageServiceProtocol {
    private let supabase = SupabaseManager.shared.client
    private let colorExtractor = ColorExtractionService()
    private let clothingExtractor: any ClothingExtracting
    private let multiGarmentExtractor: any MultiGarmentExtracting
    private let logger = Logger(subsystem: "com.wardroberedo", category: "ImageService")

    private let maxOriginalDimension: CGFloat = 1200
    private let thumbnailDimension: CGFloat = 400
    private let compressionQuality: CGFloat = 0.8

    init(
        clothingExtractor: any ClothingExtracting = ClothingExtractionService(),
        multiGarmentExtractor: any MultiGarmentExtracting = MultiGarmentProposalService()
    ) {
        self.clothingExtractor = clothingExtractor
        self.multiGarmentExtractor = multiGarmentExtractor
    }

    // MARK: - Process Image

    /// Run background extraction, resize original + thumbnail, extract
    /// colors from the masked image, prepare for upload.
    ///
    /// Color extraction runs on the MASKED image (or the original if
    /// extraction failed) so the wardrobe palette reflects the clothing
    /// itself, not the floor / wall / mirror behind it.
    func processImage(_ image: UIImage) async -> ProcessedImage? {
        // Run the single-mask path and the multi-garment path in
        // parallel. The single path is the hard requirement — its result
        // always drives the "did extraction succeed" decisions below.
        // Multi-garment is strictly additive; when it's disabled or the
        // model is missing we still ship a perfectly good ProcessedImage
        // with proposals=nil.
        async let extractionTask = clothingExtractor.extract(image)
        async let proposalsTask: [MaskProposal]? = detectProposalsIfEnabled(for: image)

        let extraction = await extractionTask
        let proposals = await proposalsTask

        guard let originalResized = resize(extraction.originalImage, maxDimension: maxOriginalDimension),
              let thumbnailResized = resize(extraction.originalImage, maxDimension: thumbnailDimension),
              let originalData = originalResized.jpegData(compressionQuality: compressionQuality),
              let thumbnailData = thumbnailResized.jpegData(compressionQuality: compressionQuality)
        else { return nil }

        // Masked version goes to storage only when extraction succeeded
        // (method != .none). PNG keeps the alpha channel so future UI
        // improvements can render the clothing on a clean background.
        let maskedData: Data?
        if extraction.method != .none,
           let maskedResized = resize(extraction.maskedImage, maxDimension: maxOriginalDimension) {
            maskedData = maskedResized.pngData()
        } else {
            maskedData = nil
        }

        let colors = await colorExtractor.extractColors(from: extraction.maskedImage)

        return ProcessedImage(
            originalData: originalData,
            thumbnailData: thumbnailData,
            maskedData: maskedData,
            extractionConfidence: extraction.confidence,
            extractionMethod: extraction.method,
            dominantColors: colors,
            proposals: proposals,
            silhouetteArea: extraction.silhouetteArea
        )
    }

    /// Feature-flagged multi-garment proposal detection. Returns nil
    /// when the flag is off, when the model isn't bundled yet, or when
    /// inference threw — callers always see a valid ProcessedImage and
    /// simply fall through to the single-item flow.
    private func detectProposalsIfEnabled(for image: UIImage) async -> [MaskProposal]? {
        guard FeatureFlags.isMultiGarmentEnabled else { return nil }
        do {
            let proposals = try await multiGarmentExtractor.detectProposals(in: image)
            // Require at least 2 proposals to trigger multi-pick UX —
            // single-proposal outputs fall through to the existing
            // single-item flow so users don't get a one-item "batch."
            return proposals.count >= 2 ? proposals : nil
        } catch {
            logger.error("multi-garment detection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Upload to Supabase Storage

    /// Upload original, thumbnail, and (when extraction succeeded) the
    /// masked PNG to Supabase Storage. Returns the four paths — the
    /// masked path is nil when we didn't produce a masked image, and the
    /// source path is nil for single-item captures (`sourcePhotoId ==
    /// nil`) or echoed back unchanged when the caller passed an
    /// `existingSourcePhotoPath`.
    ///
    /// The source-photo upload reuses `processed.originalData`: the
    /// unmasked JPEG we already resized for the per-item `image_path`
    /// also doubles as the unmasked "source of truth" for every garment
    /// row extracted from the same capture. So this costs one extra
    /// Storage write on the *first* save per capture, and zero writes on
    /// garments 2..N.
    func upload(
        processed: ProcessedImage,
        userId: UUID,
        itemId: UUID,
        sourcePhotoId: UUID?,
        existingSourcePhotoPath: String?
    ) async throws -> (imagePath: String, thumbnailPath: String, maskedImagePath: String?, sourcePhotoPath: String?) {
        // Lowercase to match Postgres auth.uid()::text in the storage RLS policy.
        // Swift's UUID.uuidString returns uppercase; the policy comparison
        // `auth.uid()::text = (storage.foldername(name))[1]` is case-sensitive,
        // so uppercase folder names get rejected as RLS violations.
        let userFolder = userId.uuidString.lowercased()
        let basePath = "\(userFolder)/\(itemId.uuidString.lowercased())"
        let imagePath = "\(basePath)/original.jpg"
        let thumbnailPath = "\(basePath)/thumb.jpg"
        let maskedPath = "\(basePath)/masked.png"

        try await supabase.storage
            .from("wardrobe-images")
            .upload(
                imagePath,
                data: processed.originalData,
                options: FileOptions(contentType: "image/jpeg")
            )

        try await supabase.storage
            .from("wardrobe-images")
            .upload(
                thumbnailPath,
                data: processed.thumbnailData,
                options: FileOptions(contentType: "image/jpeg")
            )

        let uploadedMaskedPath: String?
        if let maskedData = processed.maskedData {
            try await supabase.storage
                .from("wardrobe-images")
                .upload(
                    maskedPath,
                    data: maskedData,
                    options: FileOptions(contentType: "image/png")
                )
            uploadedMaskedPath = maskedPath
        } else {
            uploadedMaskedPath = nil
        }

        // Source-photo upload. Only runs when the caller is participating
        // in the multi-garment loop (non-nil sourcePhotoId) AND this is the
        // first save of that capture (no existingSourcePhotoPath). On
        // garments 2..N we echo the same path back so the NewWardrobeItem
        // row still gets populated but no extra Storage write fires.
        let resolvedSourcePath: String?
        if let sourcePhotoId {
            if let existing = existingSourcePhotoPath {
                resolvedSourcePath = existing
            } else {
                let sourcePath = "\(userFolder)/source/\(sourcePhotoId.uuidString.lowercased())/original.jpg"
                try await supabase.storage
                    .from("wardrobe-images")
                    .upload(
                        sourcePath,
                        data: processed.originalData,
                        options: FileOptions(contentType: "image/jpeg")
                    )
                resolvedSourcePath = sourcePath
            }
        } else {
            resolvedSourcePath = nil
        }

        return (imagePath, thumbnailPath, uploadedMaskedPath, resolvedSourcePath)
    }

    /// Get a signed URL for an image in storage.
    func signedURL(for path: String, expiresIn: Int = 3600) async throws -> URL {
        try await supabase.storage
            .from("wardrobe-images")
            .createSignedURL(path: path, expiresIn: expiresIn)
    }

    /// Re-encode a user-edited mask on top of an already-processed image
    /// and re-run color extraction. Leaves `originalData` + `thumbnailData`
    /// untouched — only the masked PNG and the color palette change.
    /// Called by `AddItemViewModel.onTouchupDone(_:)` after the user
    /// finishes brushing in `MaskTouchupView`.
    func updateMasked(
        processed: ProcessedImage,
        editedMask: UIImage
    ) async -> ProcessedImage? {
        guard let resized = resize(editedMask, maxDimension: maxOriginalDimension),
              let data = resized.pngData()
        else { return nil }
        let colors = await colorExtractor.extractColors(from: editedMask)
        return ProcessedImage(
            originalData: processed.originalData,
            thumbnailData: processed.thumbnailData,
            maskedData: data,
            extractionConfidence: processed.extractionConfidence,
            extractionMethod: processed.extractionMethod,
            dominantColors: colors,
            proposals: processed.proposals,
            // Build 6 Phase 8B — touchup edits typically refine mask
            // edges, not silhouette mass. Carrying the previously
            // computed value is "good enough" for v1; a future build
            // can re-count alpha pixels on `editedMask` if engagement
            // data shows touchup users substantially redrawing.
            silhouetteArea: processed.silhouetteArea
        )
    }

    /// Delete images for an item from storage using the stored paths.
    /// `maskedImagePath` is optional — pre-migration-00007 rows don't have
    /// a masked file, so nothing to clean up for them.
    func deleteImages(imagePath: String, thumbnailPath: String, maskedImagePath: String?) async throws {
        var paths = [imagePath, thumbnailPath]
        if let maskedImagePath {
            paths.append(maskedImagePath)
        }
        _ = try await supabase.storage
            .from("wardrobe-images")
            .remove(paths: paths)
    }

    // MARK: - Resize

    private func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height)

        if ratio >= 1.0 { return image }

        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - PhotosPickerItem Helper

extension ImageService {
    /// Loads a `PhotosPickerItem` as a downsampled `UIImage`.
    ///
    /// Build 29 — was decoding the full image via `UIImage(data:)`,
    /// which on modern phones (24–48 MP HEICs) holds 100+ MB in
    /// memory before downstream processing even starts. The Build 26
    /// camera-path downsample mirrored "what PhotosPicker does",
    /// but the audit's assumption was wrong: `loadTransferable(
    /// type: Data.self)` returns the FULL image data. Real-device
    /// testing on TF32 showed library uploads OOM-crashing just like
    /// the pre-fix camera path.
    ///
    /// Now routes through `ImageDownsampler.downsampled(from:)`,
    /// which uses `CGImageSourceCreateThumbnailAtIndex` to read the
    /// source lazily and emit a max-2048 px thumbnail without ever
    /// decoding the original at full resolution. EXIF orientation
    /// is applied so portrait photos render upright.
    func loadImage(from item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return nil
        }
        return ImageDownsampler.downsampled(from: data)
    }
}
