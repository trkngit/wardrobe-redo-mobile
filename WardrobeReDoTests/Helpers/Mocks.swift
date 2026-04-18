import Foundation
import UIKit
import SwiftUI
import PhotosUI
@testable import WardrobeReDo

// MARK: - Mock Error

enum MockError: Error, Equatable {
    case simulated
    case uploadFailed
    case insertFailed
    case networkTimeout
}

// MARK: - Mock WardrobeRepository

@MainActor
final class MockWardrobeRepository: WardrobeRepositoryProtocol {
    var fetchItemsResult: Result<[WardrobeItem], Error> = .success([])
    var fetchItemsByIdsResult: Result<[WardrobeItem], Error> = .success([])
    var archiveItemError: Error?
    var deleteItemError: Error?
    var insertItemResult: Result<WardrobeItem, Error> = .success(TestFixtures.makeWardrobeItem())

    var fetchItemsCallCount = 0
    var archiveItemCallCount = 0
    var deleteItemCallCount = 0
    var insertItemCallCount = 0
    var lastInsertedItem: NewWardrobeItem?

    func fetchItems(userId: UUID, category: ClothingCategory?) async throws -> [WardrobeItem] {
        fetchItemsCallCount += 1
        return try fetchItemsResult.get()
    }

    func fetchItems(ids: [UUID]) async throws -> [WardrobeItem] {
        return try fetchItemsByIdsResult.get()
    }

    func archiveItem(id: UUID) async throws {
        archiveItemCallCount += 1
        if let error = archiveItemError { throw error }
    }

    func deleteItem(id: UUID) async throws {
        deleteItemCallCount += 1
        if let error = deleteItemError { throw error }
    }

    func insertItem(_ item: NewWardrobeItem) async throws -> WardrobeItem {
        insertItemCallCount += 1
        lastInsertedItem = item
        return try insertItemResult.get()
    }
}

// MARK: - Mock OutfitRepository

@MainActor
final class MockOutfitRepository: OutfitRepositoryProtocol {
    var fetchOutfitsByDateResult: Result<[Outfit], Error> = .success([])
    var fetchSlotsResult: Result<[UUID: [OutfitSlot]], Error> = .success([:])
    var fetchRecentItemIdsResult: Result<Set<UUID>, Error> = .success([])
    var updateReactionError: Error?
    var markAsWornError: Error?

    var hasOutfitsForDateResult: Bool = false

    var updateReactionCallCount = 0
    var markAsWornCallCount = 0
    var hasOutfitsForDateCallCount = 0
    var lastReaction: String??
    var lastIsWorn: Bool?
    var lastOutfitId: UUID?

    func fetchOutfitsByDate(userId: UUID, date: String) async throws -> [Outfit] {
        return try fetchOutfitsByDateResult.get()
    }

    func fetchSlotsForOutfits(outfitIds: [UUID]) async throws -> [UUID: [OutfitSlot]] {
        return try fetchSlotsResult.get()
    }

    func fetchRecentItemIds(userId: UUID, days: Int) async throws -> Set<UUID> {
        return try fetchRecentItemIdsResult.get()
    }

    func updateReaction(outfitId: UUID, reaction: String?) async throws {
        updateReactionCallCount += 1
        lastOutfitId = outfitId
        lastReaction = reaction
        if let error = updateReactionError { throw error }
    }

    func markAsWorn(outfitId: UUID, isWorn: Bool) async throws {
        markAsWornCallCount += 1
        lastOutfitId = outfitId
        lastIsWorn = isWorn
        if let error = markAsWornError { throw error }
    }

    func hasOutfitsForDate(userId: UUID, date: String) async throws -> Bool {
        hasOutfitsForDateCallCount += 1
        return hasOutfitsForDateResult
    }
}

// MARK: - Mock ImageService

@MainActor
final class MockImageService: ImageServiceProtocol {
    var signedURLResult: Result<URL, Error> = .success(URL(string: "https://example.com/image.jpg")!)
    var deleteImagesError: Error?
    var uploadResult: Result<(imagePath: String, thumbnailPath: String, maskedImagePath: String?), Error> = .success((
        imagePath: "images/test.jpg",
        thumbnailPath: "thumbnails/test.jpg",
        maskedImagePath: "masked/test.png"
    ))
    /// Path returned for the source-photo component of a multi-garment
    /// upload. Mirrors the real ImageService behavior: on the first save
    /// of a capture the ImageService uploads the unmasked original and
    /// returns a path; on subsequent saves the mock (like the real impl)
    /// echoes back the existing path the caller passed in.
    var uploadSourcePhotoPath: String = "users/test/source/cap-1/original.jpg"
    var processImageResult: ProcessedImage?
    var loadImageResult: UIImage?
    var updateMaskedResult: ProcessedImage?

    var signedURLCallCount = 0
    var deleteImagesCallCount = 0
    var uploadCallCount = 0
    var processImageCallCount = 0
    var loadImageCallCount = 0
    var updateMaskedCallCount = 0
    var lastDeletedMaskedImagePath: String??
    var lastUpdateMaskedProcessed: ProcessedImage?
    var lastUpdateMaskedEditedMask: UIImage?
    var lastUploadSourcePhotoId: UUID??
    var lastUploadExistingSourcePhotoPath: String??

    func signedURL(for path: String, expiresIn: Int) async throws -> URL {
        signedURLCallCount += 1
        return try signedURLResult.get()
    }

    func deleteImages(imagePath: String, thumbnailPath: String, maskedImagePath: String?) async throws {
        deleteImagesCallCount += 1
        lastDeletedMaskedImagePath = maskedImagePath
        if let error = deleteImagesError { throw error }
    }

    func upload(
        processed: ProcessedImage,
        userId: UUID,
        itemId: UUID,
        sourcePhotoId: UUID?,
        existingSourcePhotoPath: String?
    ) async throws -> (imagePath: String, thumbnailPath: String, maskedImagePath: String?, sourcePhotoPath: String?) {
        uploadCallCount += 1
        lastUploadSourcePhotoId = sourcePhotoId
        lastUploadExistingSourcePhotoPath = existingSourcePhotoPath
        let base = try uploadResult.get()
        let resolvedSourcePath: String?
        if sourcePhotoId == nil {
            resolvedSourcePath = nil
        } else if let existing = existingSourcePhotoPath {
            resolvedSourcePath = existing
        } else {
            resolvedSourcePath = uploadSourcePhotoPath
        }
        return (base.imagePath, base.thumbnailPath, base.maskedImagePath, resolvedSourcePath)
    }

    func processImage(_ image: UIImage) async -> ProcessedImage? {
        processImageCallCount += 1
        return processImageResult
    }

    func loadImage(from item: PhotosPickerItem) async -> UIImage? {
        loadImageCallCount += 1
        return loadImageResult
    }

    func updateMasked(processed: ProcessedImage, editedMask: UIImage) async -> ProcessedImage? {
        updateMaskedCallCount += 1
        lastUpdateMaskedProcessed = processed
        lastUpdateMaskedEditedMask = editedMask
        return updateMaskedResult
    }
}

// MARK: - Mock ClothingExtractionService
//
// Phase 4 addition. Lets tests exercise the upload / color-extraction flow
// without actually spinning up Vision or SAM2. Supply canned results via
// `extractResult` / `tapPointsResult`; if either is left nil, the mock
// returns a pass-through `ExtractionResult` that echoes the input image so
// downstream code still has a valid `maskedImage` to work with.

final class MockClothingExtractionService: ClothingExtracting, @unchecked Sendable {
    var extractResult: ExtractionResult?
    var tapPointsResult: ExtractionResult?

    var extractCallCount = 0
    var tapPointsExtractCallCount = 0
    var prewarmCallCount = 0
    var lastTapPoints: [SAM2TapPoint] = []

    func extract(_ image: UIImage) async -> ExtractionResult {
        extractCallCount += 1
        return extractResult ?? MockClothingExtractionService.passThroughResult(for: image, method: .none, confidence: .failed)
    }

    func extract(_ image: UIImage, tapPoints: [SAM2TapPoint]) async -> ExtractionResult {
        tapPointsExtractCallCount += 1
        lastTapPoints = tapPoints
        return tapPointsResult ?? MockClothingExtractionService.passThroughResult(for: image, method: .sam2Manual, confidence: .high)
    }

    func prewarm() async {
        prewarmCallCount += 1
    }

    /// Builds a minimal "no-op" `ExtractionResult` that looks well-formed to
    /// callers but performs no actual segmentation. Useful when the test
    /// doesn't care about the mask itself, only the surrounding orchestration.
    static func passThroughResult(
        for image: UIImage,
        method: ExtractionMethod = .none,
        confidence: ExtractionConfidence = .failed
    ) -> ExtractionResult {
        ExtractionResult(
            originalImage: image,
            maskedImage: image,
            mask: nil,
            confidence: confidence,
            method: method
        )
    }
}

// MARK: - Mock MultiGarmentExtractor

/// Canned-response mock for `MultiGarmentExtracting`. Supply one of:
///   - `detectResult` → returns these proposals verbatim
///   - `detectError` → throws this error
/// If neither is set, returns `[]` (model ran, no garments detected).
final class MockMultiGarmentExtractor: MultiGarmentExtracting, @unchecked Sendable {
    var detectResult: [MaskProposal]?
    var detectError: Error?

    var detectCallCount = 0
    var prewarmCallCount = 0
    var lastDetectedImage: UIImage?

    func detectProposals(in image: UIImage) async throws -> [MaskProposal] {
        detectCallCount += 1
        lastDetectedImage = image
        if let detectError { throw detectError }
        return detectResult ?? []
    }

    func prewarm() async {
        prewarmCallCount += 1
    }
}

// MARK: - MaskProposal fixture helpers

enum MaskProposalFixture {
    /// 1×1 transparent pixel used as a filler `maskedImage` when tests
    /// don't care about rendering the proposal. Avoids shipping a real
    /// test asset.
    static let placeholderImage: UIImage = {
        UIGraphicsBeginImageContext(CGSize(width: 1, height: 1))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }()

    /// Convenience constructor that returns a valid `MaskProposal` with
    /// sensible defaults. Pass overrides for any field you care about;
    /// the rest stay stable so test assertions aren't coupled to noise.
    static func make(
        id: UUID = UUID(),
        maskedImage: UIImage? = nil,
        confidence: ExtractionConfidence = .high,
        predictedCategory: ClothingCategory? = .top,
        boundingBox: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        detectionScore: Float = 0.9,
        modelClassRaw: String = "shirt_blouse"
    ) -> MaskProposal {
        MaskProposal(
            id: id,
            maskedImage: maskedImage ?? placeholderImage,
            mask: nil,
            confidence: confidence,
            predictedCategory: predictedCategory,
            boundingBox: boundingBox,
            detectionScore: detectionScore,
            modelClassRaw: modelClassRaw
        )
    }
}
