import Foundation
import Observation
import os
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

    private let imageService: any ImageServiceProtocol
    private let wardrobeRepository: any WardrobeRepositoryProtocol
    private let logger = Logger(subsystem: "com.wardroberedo", category: "AddItem")

    init(
        imageService: any ImageServiceProtocol = ImageService(),
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository()
    ) {
        self.imageService = imageService
        self.wardrobeRepository = wardrobeRepository
    }

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
        defer { isSaving = false }

        let itemId = UUID()
        let colors = extractedColors
        let cat = category.rawValue
        let subcat = subcategory.rawValue
        let tex = texture?.rawValue
        let fit = fitAttribute?.rawValue
        let seasons = Array(selectedSeasons).map(\.rawValue)
        let occasions = Array(selectedOccasions).map(\.rawValue)

        logger.info("save: starting upload for itemId=\(itemId)")

        // Race the entire save operation against a 45-second timeout
        let success: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [imageService, wardrobeRepository, logger] in
                var uploadedPaths: (imagePath: String, thumbnailPath: String)?

                do {
                    let paths = try await imageService.upload(
                        processed: processed,
                        userId: userId,
                        itemId: itemId
                    )
                    uploadedPaths = paths
                    logger.info("save: upload complete, inserting item")

                    let newItem = NewWardrobeItem(
                        userId: userId,
                        imagePath: paths.imagePath,
                        thumbnailPath: paths.thumbnailPath,
                        category: cat,
                        subcategory: subcat,
                        dominantColors: colors,
                        texture: tex,
                        fitAttribute: fit,
                        seasons: seasons,
                        occasions: occasions
                    )

                    _ = try await wardrobeRepository.insertItem(newItem)
                    logger.info("save: insert complete")
                    return true
                } catch {
                    logger.error("save: failed — \(error.localizedDescription)")

                    // Cleanup: if upload succeeded but DB insert failed,
                    // delete orphaned images to prevent storage leaks
                    if let paths = uploadedPaths {
                        logger.info("save: cleaning up orphaned images")
                        try? await imageService.deleteImages(
                            imagePath: paths.imagePath,
                            thumbnailPath: paths.thumbnailPath
                        )
                    }
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return false
            }

            let result = await group.next()!
            group.cancelAll()
            return result
        }

        if success {
            didSave = true
        } else {
            errorMessage = "Failed to save item. Check your connection and try again."
            currentStep = .details
        }
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
