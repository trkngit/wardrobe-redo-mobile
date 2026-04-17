import UIKit
import PhotosUI
import SwiftUI
import Supabase

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
}

@MainActor
final class ImageService: ImageServiceProtocol {
    private let supabase = SupabaseManager.shared.client
    private let colorExtractor = ColorExtractionService()
    private let clothingExtractor: any ClothingExtracting

    private let maxOriginalDimension: CGFloat = 1200
    private let thumbnailDimension: CGFloat = 400
    private let compressionQuality: CGFloat = 0.8

    init(clothingExtractor: any ClothingExtracting = ClothingExtractionService()) {
        self.clothingExtractor = clothingExtractor
    }

    // MARK: - Process Image

    /// Run background extraction, resize original + thumbnail, extract
    /// colors from the masked image, prepare for upload.
    ///
    /// Color extraction runs on the MASKED image (or the original if
    /// extraction failed) so the wardrobe palette reflects the clothing
    /// itself, not the floor / wall / mirror behind it.
    func processImage(_ image: UIImage) async -> ProcessedImage? {
        let extraction = await clothingExtractor.extract(image)

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
            dominantColors: colors
        )
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
            dominantColors: colors
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
    func loadImage(from item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }
}
