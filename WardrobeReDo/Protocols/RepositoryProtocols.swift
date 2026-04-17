import Foundation
import UIKit
import SwiftUI
import PhotosUI

// MARK: - Repository Protocols for Dependency Injection

/// WardrobeRepository interface for ViewModels.
@MainActor
protocol WardrobeRepositoryProtocol: Sendable {
    func fetchItems(userId: UUID, category: ClothingCategory?) async throws -> [WardrobeItem]
    func fetchItems(ids: [UUID]) async throws -> [WardrobeItem]
    func archiveItem(id: UUID) async throws
    func deleteItem(id: UUID) async throws
    func insertItem(_ item: NewWardrobeItem) async throws -> WardrobeItem
}

extension WardrobeRepositoryProtocol {
    func fetchItems(userId: UUID) async throws -> [WardrobeItem] {
        try await fetchItems(userId: userId, category: nil)
    }
}

/// OutfitRepository interface for ViewModels.
@MainActor
protocol OutfitRepositoryProtocol: Sendable {
    func fetchOutfitsByDate(userId: UUID, date: String) async throws -> [Outfit]
    func fetchSlotsForOutfits(outfitIds: [UUID]) async throws -> [UUID: [OutfitSlot]]
    func fetchRecentItemIds(userId: UUID, days: Int) async throws -> Set<UUID>
    func updateReaction(outfitId: UUID, reaction: String?) async throws
    func markAsWorn(outfitId: UUID, isWorn: Bool) async throws
    func hasOutfitsForDate(userId: UUID, date: String) async throws -> Bool
}

extension OutfitRepositoryProtocol {
    func fetchRecentItemIds(userId: UUID) async throws -> Set<UUID> {
        try await fetchRecentItemIds(userId: userId, days: 7)
    }
}

/// ImageService interface for ViewModels.
@MainActor
protocol ImageServiceProtocol: Sendable {
    func signedURL(for path: String, expiresIn: Int) async throws -> URL
    func deleteImages(imagePath: String, thumbnailPath: String) async throws
    func upload(processed: ProcessedImage, userId: UUID, itemId: UUID) async throws -> (imagePath: String, thumbnailPath: String)
    func processImage(_ image: UIImage) async -> ProcessedImage?
    func loadImage(from item: PhotosPickerItem) async -> UIImage?
}

extension ImageServiceProtocol {
    func signedURL(for path: String) async throws -> URL {
        try await signedURL(for: path, expiresIn: 3600)
    }
}
