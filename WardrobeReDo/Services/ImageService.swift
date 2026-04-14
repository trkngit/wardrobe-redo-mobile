import UIKit
import PhotosUI
import SwiftUI
import Supabase

struct ProcessedImage: Sendable {
    let originalData: Data
    let thumbnailData: Data
    let dominantColors: [ExtractedColor]
}

@MainActor
final class ImageService {
    private let supabase = SupabaseManager.shared.client
    private let colorExtractor = ColorExtractionService()

    private let maxOriginalDimension: CGFloat = 1200
    private let thumbnailDimension: CGFloat = 400
    private let compressionQuality: CGFloat = 0.8

    // MARK: - Process Image

    /// Resize image, extract colors, prepare for upload.
    func processImage(_ image: UIImage) async -> ProcessedImage? {
        guard let originalResized = resize(image, maxDimension: maxOriginalDimension),
              let thumbnailResized = resize(image, maxDimension: thumbnailDimension),
              let originalData = originalResized.jpegData(compressionQuality: compressionQuality),
              let thumbnailData = thumbnailResized.jpegData(compressionQuality: compressionQuality)
        else { return nil }

        let colors = await colorExtractor.extractColors(from: image)

        return ProcessedImage(
            originalData: originalData,
            thumbnailData: thumbnailData,
            dominantColors: colors
        )
    }

    // MARK: - Upload to Supabase Storage

    /// Upload original + thumbnail to Supabase Storage. Returns (imagePath, thumbnailPath).
    func upload(
        processed: ProcessedImage,
        userId: UUID,
        itemId: UUID
    ) async throws -> (imagePath: String, thumbnailPath: String) {
        let basePath = "\(userId.uuidString)/\(itemId.uuidString)"
        let imagePath = "\(basePath)/original.jpg"
        let thumbnailPath = "\(basePath)/thumb.jpg"

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

        return (imagePath, thumbnailPath)
    }

    /// Get a signed URL for an image in storage.
    func signedURL(for path: String, expiresIn: Int = 3600) async throws -> URL {
        try await supabase.storage
            .from("wardrobe-images")
            .createSignedURL(path: path, expiresIn: expiresIn)
    }

    /// Delete images for an item from storage.
    func deleteImages(userId: UUID, itemId: UUID) async throws {
        let basePath = "\(userId.uuidString)/\(itemId.uuidString)"
        _ = try await supabase.storage
            .from("wardrobe-images")
            .remove(paths: ["\(basePath)/original.jpg", "\(basePath)/thumb.jpg"])
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
