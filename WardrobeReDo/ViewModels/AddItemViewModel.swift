import Foundation
import Observation
import UIKit
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class AddItemViewModel {
    // MARK: - State

    enum Step: Int, CaseIterable {
        case photo = 0
        case analysis = 1
        case details = 2
        case saving = 3
    }

    var currentStep: Step = .photo
    var selectedPhoto: PhotosPickerItem?
    var selectedImage: UIImage?
    var processedImage: ProcessedImage?

    // Item metadata
    var category: ClothingCategory = .top
    var subcategory: ClothingSubcategory = .tshirt
    var texture: TextureType?
    var fitAttribute: FitAttribute?
    var selectedSeasons: Set<Season> = Set(Season.allCases)
    var selectedOccasions: Set<Occasion> = [.casual]

    // UI state
    var isProcessing = false
    var isSaving = false
    var errorMessage: String?
    var didSave = false

    // MARK: - Dependencies

    private let imageService = ImageService()
    private let wardrobeRepository = WardrobeRepository()

    // MARK: - Computed

    var extractedColors: [ColorProfile] {
        processedImage?.dominantColors.map { $0.toColorProfile() } ?? []
    }

    var availableSubcategories: [ClothingSubcategory] {
        ClothingSubcategory.subcategories(for: category)
    }

    var canSave: Bool {
        processedImage != nil && !isSaving
    }

    // MARK: - Actions

    func onPhotoSelected() async {
        guard let item = selectedPhoto else { return }

        isProcessing = true
        errorMessage = nil
        currentStep = .analysis

        guard let image = await imageService.loadImage(from: item) else {
            errorMessage = "Couldn't load that image. Try another one."
            currentStep = .photo
            isProcessing = false
            return
        }

        selectedImage = image

        guard let processed = await imageService.processImage(image) else {
            errorMessage = "Couldn't process that image. Try another one."
            currentStep = .photo
            isProcessing = false
            return
        }

        processedImage = processed
        isProcessing = false
        currentStep = .details
    }

    func onCategoryChanged() {
        let subs = availableSubcategories
        if !subs.contains(subcategory), let first = subs.first {
            subcategory = first
        }
    }

    func save(userId: UUID) async {
        guard let processed = processedImage else { return }

        isSaving = true
        currentStep = .saving
        errorMessage = nil

        let itemId = UUID()

        do {
            let (imagePath, thumbnailPath) = try await imageService.upload(
                processed: processed,
                userId: userId,
                itemId: itemId
            )

            let newItem = NewWardrobeItem(
                userId: userId,
                imagePath: imagePath,
                thumbnailPath: thumbnailPath,
                category: category.rawValue,
                subcategory: subcategory.rawValue,
                dominantColors: extractedColors,
                texture: texture?.rawValue,
                fitAttribute: fitAttribute?.rawValue,
                seasons: Array(selectedSeasons).map(\.rawValue),
                occasions: Array(selectedOccasions).map(\.rawValue)
            )

            _ = try await wardrobeRepository.insertItem(newItem)
            didSave = true
        } catch {
            errorMessage = "Failed to save item: \(error.localizedDescription)"
            currentStep = .details
        }

        isSaving = false
    }

    func reset() {
        currentStep = .photo
        selectedPhoto = nil
        selectedImage = nil
        processedImage = nil
        category = .top
        subcategory = .tshirt
        texture = nil
        fitAttribute = nil
        selectedSeasons = Set(Season.allCases)
        selectedOccasions = [.casual]
        isProcessing = false
        isSaving = false
        errorMessage = nil
        didSave = false
    }
}
