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

/// Build 41 — errors thrown explicitly by ImageService for cases the
/// underlying Supabase / Vision / Core Image SDKs don't model with a
/// useful type. Currently only models the per-file upload timeout
/// (H3 mitigation); other failure modes still surface the SDK error.
enum ImageServiceError: LocalizedError {
    case uploadTimeout(String)

    var errorDescription: String? {
        switch self {
        case .uploadTimeout(let label):
            return "Upload timed out for \(label)."
        }
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

    /// Build 41 (H3 mitigation) — per-file Supabase Storage upload
    /// budget. The save-level 45 s timeout in `AddItemViewModel`
    /// catches a stalled save overall, but a single hung file
    /// (network blip on the largest payload) eats most of that
    /// budget before the race fires. Wrapping each individual
    /// `.upload(...)` in a 20 s per-file race makes the breadcrumb
    /// chain ("upload.thumbnail.start" with no matching
    /// "upload.thumbnail.end" in 20 s) point directly at the file
    /// that hung, AND surfaces a faster, more actionable user-
    /// visible failure. 20 s is comfortably above the 99th-
    /// percentile happy path (< 2 s per file on LTE) and well under
    /// the save-level 45 s ceiling so a single timeout still leaves
    /// room for cleanup.
    private let perFileUploadTimeoutSeconds: UInt64 = 20

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
    ///
    /// **Build 45 — RF-DETR-first single-item path.** TestFlight user
    /// reported that a mirror selfie wearing a jersey ended up with the
    /// WHOLE PERSON cropped as the wardrobe item. Tracing: Vision's
    /// foreground request returns the salient subject of the frame, and
    /// the salient subject in a mirror selfie IS the person — not the
    /// jersey. The RF-DETR multi-garment detector, running in parallel,
    /// had detected the clothing correctly; we just weren't using its
    /// output because the existing flow only surfaced it when the
    /// per-photo proposal count was ≥ 2 (= "multi-pick grid"). The
    /// single-proposal case fell through to Vision.
    ///
    /// TF45 inverts the priority for the single-item case:
    ///   * ≥ 2 proposals → multi-pick grid (unchanged)
    ///   * exactly 1 proposal → use THAT proposal as the cutout source,
    ///                          marked `.multiGarmentRFDETR`. Vision
    ///                          never crowns the person mask in this
    ///                          path.
    ///   * 0 proposals → fall through to Vision / SAM2-auto exactly as
    ///                   before. Legacy path is preserved as the safety
    ///                   net for flat-lay shots RF-DETR doesn't recognise.
    func processImage(_ image: UIImage) async -> ProcessedImage? {
        // Run the single-mask path and the multi-garment path in
        // parallel. The single path is the legacy fallback — its result
        // still drives the "did extraction succeed" decisions when
        // RF-DETR has nothing to say. Multi-garment is now the preferred
        // single-item source whenever it produces a proposal.
        async let extractionTask = clothingExtractor.extract(image)
        async let proposalsTask: [MaskProposal]? = detectAllProposalsIfEnabled(for: image)

        let visionExtraction = await extractionTask
        let allProposals = await proposalsTask

        // Pick the source-of-truth `ExtractionResult`:
        //   * proposals.count == 1 — promote the proposal to extraction
        //     result. Vision's result is dropped.
        //   * otherwise — use the Vision / SAM2-auto chain's result.
        let extraction: ExtractionResult
        if let single = allProposals, single.count == 1 {
            extraction = ClothingExtractionService.extractionResult(
                from: single[0],
                originalImage: visionExtraction.originalImage
            )
        } else {
            extraction = visionExtraction
        }

        // The `proposals` field on `ProcessedImage` still drives the
        // multi-pick grid in `AddItemViewModel.routeAfterProcessing`.
        // Only populate it when count ≥ 2 — single-proposal results
        // are already consumed above via the extraction-result path,
        // and zero-proposal results should pass nil downstream so
        // routing falls through to the single-item flow.
        let proposalsForRouting: [MaskProposal]?
        if let all = allProposals, all.count >= 2 {
            proposalsForRouting = all
        } else {
            proposalsForRouting = nil
        }

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

        logger.info("processImage.routing source=\(extraction.method.rawValue, privacy: .public) proposalsRaw=\(allProposals?.count ?? 0, privacy: .public) confidence=\(extraction.confidence.rawValue, privacy: .public)")

        return ProcessedImage(
            originalData: originalData,
            thumbnailData: thumbnailData,
            maskedData: maskedData,
            extractionConfidence: extraction.confidence,
            extractionMethod: extraction.method,
            dominantColors: colors,
            proposals: proposalsForRouting,
            silhouetteArea: extraction.silhouetteArea
        )
    }

    /// Build 46 — reconstruct a `ProcessedImage` from a known source
    /// photo + a chosen masked cutout WITHOUT re-running extraction.
    ///
    /// Used by the batch-restore path. A persisted multi-pick batch
    /// stores the source photo PNG and each proposal's masked cutout,
    /// but NOT the encoded `ProcessedImage` (original/thumbnail/masked
    /// data). Before this method, restoring a batch left
    /// `AddItemViewModel.processedImage == nil`, which:
    ///   * made `canSave` return false → the Save button was disabled, and
    ///   * made `save()` early-return on its `guard let processed` —
    /// so the user saw their selection restored but **could not save it**
    /// (the exact TestFlight report: "en sonki seçim tekrar geliyor
    /// fakat ürünü kaydedemiyorsun").
    ///
    /// Mirrors the encoding `processImage` performs so a restored save
    /// is byte-identical to a fresh one.
    func reconstructProcessedImage(
        source: UIImage,
        maskedImage: UIImage,
        confidence: ExtractionConfidence,
        method: ExtractionMethod
    ) async -> ProcessedImage? {
        guard let originalResized = resize(source, maxDimension: maxOriginalDimension),
              let thumbnailResized = resize(source, maxDimension: thumbnailDimension),
              let originalData = originalResized.jpegData(compressionQuality: compressionQuality),
              let thumbnailData = thumbnailResized.jpegData(compressionQuality: compressionQuality)
        else { return nil }

        let maskedData: Data?
        if method != .none, let maskedResized = resize(maskedImage, maxDimension: maxOriginalDimension) {
            maskedData = maskedResized.pngData()
        } else {
            maskedData = nil
        }

        let colors = await colorExtractor.extractColors(from: maskedImage)

        return ProcessedImage(
            originalData: originalData,
            thumbnailData: thumbnailData,
            maskedData: maskedData,
            extractionConfidence: confidence,
            extractionMethod: method,
            dominantColors: colors,
            proposals: nil
        )
    }

    /// Build 45 — returns ALL proposals (or nil when the feature flag
    /// is off / model missing / inference threw). The previous
    /// `detectProposalsIfEnabled` collapsed counts < 2 to nil so the
    /// caller couldn't distinguish "model found 1 jersey" from "model
    /// found nothing"; `processImage` now wants both signals.
    private func detectAllProposalsIfEnabled(for image: UIImage) async -> [MaskProposal]? {
        guard FeatureFlags.isMultiGarmentEnabled else { return nil }
        do {
            let proposals = try await multiGarmentExtractor.detectProposals(in: image)
            return proposals.isEmpty ? nil : proposals
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

        // Build 40 — per-file breadcrumbs around each Supabase upload.
        // Distinguishes a true crash (no `.end` log after `.start`) from
        // a silent hang (long gap between `.start` and `.end`) from a
        // user-cancelled flow (no logs at all).
        //
        // Build 41 — each per-file upload now runs through
        // `uploadWithTimeout` (defined below) so a single hung file
        // surfaces as `upload.X.timeout` after 20 s instead of letting
        // the save-level 45 s budget absorb it. The breadcrumb chain
        // points directly at the offending file.
        try await uploadWithTimeout(
            label: "original",
            bytes: processed.originalData.count,
            path: imagePath,
            data: processed.originalData,
            contentType: "image/jpeg"
        )
        try await uploadWithTimeout(
            label: "thumbnail",
            bytes: processed.thumbnailData.count,
            path: thumbnailPath,
            data: processed.thumbnailData,
            contentType: "image/jpeg"
        )

        let uploadedMaskedPath: String?
        if let maskedData = processed.maskedData {
            try await uploadWithTimeout(
                label: "masked",
                bytes: maskedData.count,
                path: maskedPath,
                data: maskedData,
                contentType: "image/png"
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
                try await uploadWithTimeout(
                    label: "source",
                    bytes: processed.originalData.count,
                    path: sourcePath,
                    data: processed.originalData,
                    contentType: "image/jpeg"
                )
                resolvedSourcePath = sourcePath
            }
        } else {
            resolvedSourcePath = nil
        }

        return (imagePath, thumbnailPath, uploadedMaskedPath, resolvedSourcePath)
    }

    /// Build 41 (H3 mitigation) — wrap a single Supabase Storage
    /// upload in a `Task.sleep` race so we surface a clear timeout
    /// per file rather than absorbing the silent hang into the
    /// `save`-level 45 s budget. The `label` is the same string used
    /// by the breadcrumb pair (`upload.original.start` /
    /// `upload.original.end`); on timeout we emit
    /// `upload.X.timeout` so a Console / Sentry breadcrumb scan
    /// names the offending file directly.
    ///
    /// Throws `ImageServiceError.uploadTimeout(label)` on race-loss
    /// so the caller's existing catch-and-cleanup path runs.
    /// Throws whatever Supabase threw if the upload itself fails.
    private func uploadWithTimeout(
        label: StaticString,
        bytes: Int,
        path: String,
        data: Data,
        contentType: String
    ) async throws {
        logger.info("upload.\(label).start bytes=\(bytes, privacy: .public)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [supabase] in
                try await supabase.storage
                    .from("wardrobe-images")
                    .upload(
                        path,
                        data: data,
                        options: FileOptions(contentType: contentType)
                    )
            }
            group.addTask { [perFileUploadTimeoutSeconds] in
                try await Task.sleep(nanoseconds: perFileUploadTimeoutSeconds * 1_000_000_000)
                throw ImageServiceError.uploadTimeout(String(describing: label))
            }
            // First-to-finish wins; cancel the other (sleep + the
            // upload's URLSession task both honour cancellation).
            try await group.next()
            group.cancelAll()
        }
        logger.info("upload.\(label).end ok=true")
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
        // Build 46 — pin the renderer scale to 1. The default
        // `UIGraphicsImageRenderer(size:)` format inherits the device
        // display scale (2× or 3×), so `resize(maxDimension: 1200)` was
        // silently producing a 3600×3600 PIXEL bitmap on a 3× iPhone.
        // The masked PNG (`pngData()` of that bitmap) ballooned to
        // ~30 MB and the transient encode held ~38 MB — the dominant
        // contributor to the "crashes when uploading" WatchdogTermination
        // (OOM) reports. These artifacts are encoded straight to file
        // data (JPEG / PNG) where points-vs-pixels is meaningless: we
        // want exactly `maxDimension` PIXELS. Display targets cap at
        // ~1200 px (full-screen item detail on a 3× phone), so there is
        // zero visible quality loss — only the wasted 9× memory goes.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
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
