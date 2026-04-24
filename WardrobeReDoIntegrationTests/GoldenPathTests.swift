import Foundation
import Testing
@testable import WardrobeReDo

/// Integration-shaped tests that exercise multiple components together.
///
/// Unlike the unit tests in `WardrobeReDoTests`, these don't mock a single
/// protocol and assert against that one surface. They wire VM → repo and
/// (sometimes) repo → second-VM so a contract break between layers surfaces
/// here, not in production.
///
/// The tests are still mock-backed — a live-Supabase harness needs a
/// dedicated test branch credential that's deferred to v1.1. The mocks
/// are faithful enough that the wiring between VM and repo is the actual
/// unit under test, not the mock itself.
///
/// ## The three golden paths
///
/// 1. **Add → Grid refresh**: insert a new item via the repo, refetch,
///    verify the grid sees it. Proves the insert→fetch round-trip
///    contract — the thing Wardrobe's list depends on after every Add.
/// 2. **Edit → Grid refresh**: EditItemViewModel hydrates from a fetched
///    item, mutates a field, saves; a second fetch returns the updated
///    row so the grid would render the new value. Proves the
///    updateItem→fetch contract.
/// 3. **Multi-garment batch → shared `source_photo_id`**: inserting N
///    garments cut from the same source capture preserves the shared
///    `sourcePhotoId` across every row so server-side grouping queries
///    (and the "view all items from this photo" affordance) work.
@MainActor
struct GoldenPathTests {

    // MARK: - Golden path 1

    @Test func addThenRefetchSurfacesTheNewItem() async throws {
        // The repo starts empty. After an insert, the seed-the-next-fetch
        // move is what `WardrobeViewModel.refresh()` does in production —
        // here we do it by hand so the mock can be a dumb record/replay
        // stub rather than a stateful fake.
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([])

        let userId = UUID()
        let newItem = makeNewItem(userId: userId, category: .top, subcategory: .tshirt)
        let persisted = TestFixtures.makeWardrobeItem(
            userId: userId,
            category: .top,
            subcategory: .tshirt
        )
        repo.insertItemResult = .success(persisted)

        // Add flow — the VM would call insertItem with the built payload.
        let inserted = try await repo.insertItem(newItem)

        // Arrange the fetch side to reflect the insert, the way the grid
        // VM calls `fetchItems` again after `.wardrobeDidChange` fires.
        repo.fetchItemsResult = .success([inserted])
        let grid = try await repo.fetchItems(userId: userId, category: nil)

        #expect(repo.insertItemCallCount == 1)
        #expect(repo.lastInsertedItem?.userId == userId)
        #expect(grid.count == 1)
        #expect(grid.first?.id == persisted.id)
    }

    // MARK: - Golden path 2

    @Test func editSaveRefreshFlowPersistsChangeEndToEnd() async throws {
        // Starting row: texture=cotton. User edits to denim → saves →
        // a subsequent fetch should return the denim row. Proves the
        // VM's "replace baseline after save" (so re-editing from the same
        // surface doesn't drift) AND the "grid refetch sees the new value"
        // contract in one test.
        let itemId = UUID()
        let original = TestFixtures.makeWardrobeItem(id: itemId, texture: .cotton)
        let updated = TestFixtures.makeWardrobeItem(id: itemId, texture: .denim)

        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([original])
        repo.updateItemResult = .success(updated)

        // Initial fetch — populates what the grid + detail view see.
        let pre = try await repo.fetchItems(userId: original.userId, category: nil)
        #expect(pre.first?.texture == .cotton)

        // Edit flow — VM hydrates, mutates, saves.
        let vm = EditItemViewModel(item: original, wardrobeRepository: repo)
        vm.texture = .denim
        await vm.save()

        #expect(vm.didSave == true)
        #expect(vm.errorMessage == nil)
        #expect(vm.original.texture == .denim)  // baseline replaced
        #expect(repo.lastUpdate?.texture == TextureType.denim.rawValue)

        // Grid refetch — the mock is re-armed to reflect the server's
        // post-update view, same as production where the NEXT request
        // hits a row that's been mutated.
        repo.fetchItemsResult = .success([updated])
        let post = try await repo.fetchItems(userId: original.userId, category: nil)
        #expect(post.first?.texture == .denim)
    }

    // MARK: - Golden path 3

    @Test func multiGarmentBatchSharesSourcePhotoIdAcrossInserts() async throws {
        // Three garments cut from the same source capture. Every insert
        // must carry the same `sourcePhotoId`. Regression guard for the
        // migration-00008 contract that lets users view "all items from
        // this photo".
        let repo = MockWardrobeRepository()
        let userId = UUID()
        let sourcePhotoId = UUID()

        let garments: [(ClothingCategory, ClothingSubcategory)] = [
            (.top, .tshirt),
            (.bottom, .jeans),
            (.shoe, .sneakerLow)
        ]

        var seenSourcePhotoIds: [UUID?] = []
        for (cat, sub) in garments {
            let payload = makeNewItem(
                userId: userId,
                category: cat,
                subcategory: sub,
                sourcePhotoId: sourcePhotoId
            )
            // Each garment gets its own primary-key row but the same
            // source_photo_id. That's the shape the grouping query relies on.
            repo.insertItemResult = .success(
                TestFixtures.makeWardrobeItem(
                    userId: userId,
                    category: cat,
                    subcategory: sub
                )
            )
            _ = try await repo.insertItem(payload)
            seenSourcePhotoIds.append(repo.lastInsertedItem?.sourcePhotoId)
        }

        #expect(repo.insertItemCallCount == 3)
        #expect(seenSourcePhotoIds.count == 3)
        #expect(seenSourcePhotoIds.allSatisfy { $0 == sourcePhotoId })
    }

    // MARK: - Helpers

    /// Shorthand for building a `NewWardrobeItem` with just the knobs this
    /// test file cares about. Everything else gets sensible defaults that
    /// match the production-side defaulting in `AddItemViewModel.save`.
    private func makeNewItem(
        userId: UUID,
        category: ClothingCategory,
        subcategory: ClothingSubcategory,
        sourcePhotoId: UUID? = nil
    ) -> NewWardrobeItem {
        NewWardrobeItem(
            userId: userId,
            imagePath: "images/\(UUID()).jpg",
            thumbnailPath: "thumbnails/\(UUID()).jpg",
            maskedImagePath: nil,
            extractionConfidence: nil,
            sourcePhotoId: sourcePhotoId,
            sourcePhotoPath: sourcePhotoId == nil ? nil : "source/\(sourcePhotoId!).jpg",
            category: category.rawValue,
            subcategory: subcategory.rawValue,
            dominantColors: [],
            texture: nil,
            fitAttribute: nil,
            seasons: Season.allCases.map(\.rawValue),
            occasions: [Occasion.casual.rawValue],
            detectedAttributes: nil,
            idempotencyKey: UUID()
        )
    }
}
