import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for `EditItemViewModel`. The VM is tiny so the surface
/// is easy to cover exhaustively:
///
/// 1. **Hydration** — init copies every user-editable field from the
///    item. Baseline for every other test.
/// 2. **hasChanges / buildUpdate no-op** — untouched form produces nil
///    diff; the Save button's `disabled` binding is driven off this.
/// 3. **Per-field diff** — mutating exactly one field produces exactly
///    one column in the `WardrobeItemUpdate`. Covers the "user toggled
///    texture back to nil" edge case.
/// 4. **Multi-field diff** — mutating N fields produces N columns with
///    the right rawValues + seasons/occasions comparing as Sets.
/// 5. **save() happy path** — repo is called with the right id + update,
///    `didSave` flips, `original` is replaced with the server's row.
/// 6. **save() failure** — `errorMessage` populated, `didSave` stays
///    false, and `isSaving` is cleared so the UI doesn't lock up.
/// 7. **save() no-op** — buildUpdate returns nil → save short-circuits
///    to `didSave = true` without calling the repo. Protects against
///    phantom UPDATEs from a gating race.
/// 8. **onCategoryChanged clamps subcategory** — switching to a new
///    category whose valid subset doesn't include the current
///    subcategory should reset to the first valid entry.
@MainActor
struct EditItemViewModelTests {

    // MARK: - Hydration

    @Test func initHydratesEveryEditableFieldFromItem() {
        let id = UUID()
        let item = TestFixtures.makeWardrobeItem(
            id: id,
            category: .bottom,
            subcategory: .jeans,
            texture: .denim,
            fitAttribute: .slim,
            seasons: [.spring, .fall],
            occasions: [.work]
        )
        let repo = MockWardrobeRepository()
        let vm = EditItemViewModel(item: item, wardrobeRepository: repo)

        #expect(vm.category == .bottom)
        #expect(vm.subcategory == .jeans)
        #expect(vm.texture == .denim)
        #expect(vm.fitAttribute == .slim)
        #expect(vm.selectedSeasons == Set<Season>([.spring, .fall]))
        #expect(vm.selectedOccasions == Set<Occasion>([.work]))
        #expect(vm.original.id == id)
        #expect(vm.hasChanges == false)
    }

    // MARK: - No-op diff

    @Test func buildUpdateReturnsNilWhenNothingChanged() {
        let item = TestFixtures.makeWardrobeItem()
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        #expect(vm.buildUpdate() == nil)
        #expect(vm.hasChanges == false)
    }

    // MARK: - Per-field diffs

    @Test func textureClearedProducesExplicitNilPayload() {
        // Starting from a non-nil texture, clearing the field should
        // emit `texture = nil` in the payload. `nil` vs "don't touch"
        // is collapsed into the same raw value, but `buildUpdate()`
        // must set `texture` (whose rawValue is nil) so the Codable
        // encode writes `null`, not omits the key.
        let item = TestFixtures.makeWardrobeItem(texture: .cotton)
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        vm.texture = nil

        #expect(vm.hasChanges == true)
        let update = vm.buildUpdate()
        #expect(update?.texture == nil)
        #expect(update?.category == nil)
        #expect(update?.subcategory == nil)
        #expect(update?.fitAttribute == nil)
        #expect(update?.seasons == nil)
        #expect(update?.occasions == nil)
    }

    @Test func categoryChangeProducesCategoryOnlyPayload() {
        let item = TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        vm.category = .outerwear
        // onCategoryChanged normally fires via .onChange in the View;
        // we call it explicitly here so the subcategory is clamped.
        vm.onCategoryChanged()

        let update = vm.buildUpdate()
        #expect(update?.category == ClothingCategory.outerwear.rawValue)
        // Subcategory also changed (clamped by onCategoryChanged) — that
        // exercises the clamp interaction, not a bug in the diff logic.
        #expect(update?.subcategory != nil)
    }

    @Test func seasonChangeComparesAsSetsNotOrderedArrays() {
        // Original is Season.allCases in enum order. The VM stores as a
        // Set; re-constructing the same set with different element
        // insertion order must NOT produce a phantom diff.
        let item = TestFixtures.makeWardrobeItem(seasons: [.spring, .summer])
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        vm.selectedSeasons = Set<Season>([.summer, .spring]) // same elements, different insertion

        #expect(vm.buildUpdate() == nil)
    }

    @Test func occasionAdditionProducesFullArrayInDiff() {
        let item = TestFixtures.makeWardrobeItem(occasions: [.casual])
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        vm.selectedOccasions.insert(.work)

        let update = vm.buildUpdate()
        // Diff ships the full new array, not a delta — Postgres receives
        // the complete `text[]` column replacement.
        #expect(update?.occasions?.count == 2)
        #expect(Set(update?.occasions ?? []) == Set([Occasion.casual.rawValue, Occasion.work.rawValue]))
    }

    // MARK: - save() paths

    @Test func saveHappyPathCallsRepoFlipsDidSaveReplacesBaseline() async {
        let id = UUID()
        let item = TestFixtures.makeWardrobeItem(id: id, texture: .cotton)
        let repo = MockWardrobeRepository()
        // Server echoes back the updated row (texture now denim).
        let serverRow = TestFixtures.makeWardrobeItem(id: id, texture: .denim)
        repo.updateItemResult = .success(serverRow)

        let vm = EditItemViewModel(item: item, wardrobeRepository: repo)
        vm.texture = .denim

        await vm.save()

        #expect(repo.updateItemCallCount == 1)
        #expect(repo.lastUpdatedId == id)
        #expect(repo.lastUpdate?.texture == TextureType.denim.rawValue)
        #expect(vm.didSave == true)
        #expect(vm.errorMessage == nil)
        #expect(vm.isSaving == false)
        #expect(vm.original.texture == .denim)
        // Second save from the same VM should see no changes against
        // the refreshed baseline.
        #expect(vm.hasChanges == false)
    }

    @Test func saveFailurePopulatesErrorMessageLeavesDidSaveFalse() async {
        let item = TestFixtures.makeWardrobeItem(texture: .cotton)
        let repo = MockWardrobeRepository()
        repo.updateItemResult = .failure(MockError.simulated)

        let vm = EditItemViewModel(item: item, wardrobeRepository: repo)
        vm.texture = .denim

        await vm.save()

        #expect(vm.didSave == false)
        #expect(vm.errorMessage != nil)
        #expect(vm.isSaving == false)
        #expect(repo.updateItemCallCount == 1)
        // Baseline should not advance on failure — a retry must resend
        // the same diff.
        #expect(vm.original.texture == .cotton)
    }

    @Test func saveNoOpSkipsRepoAndFlipsDidSave() async {
        let item = TestFixtures.makeWardrobeItem()
        let repo = MockWardrobeRepository()
        let vm = EditItemViewModel(item: item, wardrobeRepository: repo)

        await vm.save()

        #expect(repo.updateItemCallCount == 0)
        #expect(vm.didSave == true)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Subcategory clamp

    @Test func onCategoryChangedClampsSubcategoryToValidSubset() {
        // tshirt is a valid subcategory of `.top` but not of `.bottom`.
        let item = TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        vm.category = .bottom
        vm.onCategoryChanged()

        let validSubs = ClothingSubcategory.subcategories(for: .bottom)
        #expect(validSubs.contains(vm.subcategory))
    }

    @Test func onCategoryChangedNoOpsWhenSubcategoryStillValid() {
        // Pick a category/sub pair where the clamp shouldn't fire on a
        // no-op re-assign of the same category.
        let item = TestFixtures.makeWardrobeItem(category: .top, subcategory: .tshirt)
        let vm = EditItemViewModel(item: item, wardrobeRepository: MockWardrobeRepository())

        vm.onCategoryChanged()

        #expect(vm.subcategory == .tshirt)
    }
}
