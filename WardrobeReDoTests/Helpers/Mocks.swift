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
    var uploadResult: Result<(imagePath: String, thumbnailPath: String), Error> = .success((imagePath: "images/test.jpg", thumbnailPath: "thumbnails/test.jpg"))
    var processImageResult: ProcessedImage?
    var loadImageResult: UIImage?

    var signedURLCallCount = 0
    var deleteImagesCallCount = 0
    var uploadCallCount = 0
    var processImageCallCount = 0
    var loadImageCallCount = 0

    func signedURL(for path: String, expiresIn: Int) async throws -> URL {
        signedURLCallCount += 1
        return try signedURLResult.get()
    }

    func deleteImages(imagePath: String, thumbnailPath: String) async throws {
        deleteImagesCallCount += 1
        if let error = deleteImagesError { throw error }
    }

    func upload(processed: ProcessedImage, userId: UUID, itemId: UUID) async throws -> (imagePath: String, thumbnailPath: String) {
        uploadCallCount += 1
        return try uploadResult.get()
    }

    func processImage(_ image: UIImage) async -> ProcessedImage? {
        processImageCallCount += 1
        return processImageResult
    }

    func loadImage(from item: PhotosPickerItem) async -> UIImage? {
        loadImageCallCount += 1
        return loadImageResult
    }
}
