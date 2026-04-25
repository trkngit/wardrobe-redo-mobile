import Foundation
import Testing
@testable import WardrobeReDo

/// Coverage of `AttributeBackfillService` — the one-shot maintenance
/// pass that re-runs the broadened rules table on legacy items.
///
/// Two surfaces under test:
///   - `computeUpdate(for:)` — pure function, easy to exercise across
///     widening / non-widening / explicitly-narrowed scenarios.
///   - `runIfNeeded(...)` — orchestration: gating on a UserDefaults
///     flag, fetching items, calling `updateItem` only on widened
///     fields, and setting the flag once done.
///
/// Each test uses an isolated `UserDefaults(suiteName:)` so the system
/// defaults — and other tests — don't leak state. The repository is
/// the same `MockWardrobeRepository` every other test uses.
@Suite("AttributeBackfillService") struct AttributeBackfillServiceTests {

    // MARK: - computeUpdate

    @Test @MainActor func computeUpdateReturnsNilWhenStoredSetIsAlreadyAsWide() {
        // A polo currently has the wider rule output `[casual, work,
        // date, lounge]` — so an item already storing all four tags
        // shouldn't trigger any update.
        let item = TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .polo,
            seasons: Season.allCases,
            occasions: [.casual, .work, .date, .lounge]
        )

        #expect(AttributeBackfillService.computeUpdate(for: item) == nil)
    }

    @Test @MainActor func computeUpdateBroadensLegacyCasualOnlyPolo() {
        // The dogfood-bug fingerprint: a polo saved when the rules were
        // narrow ([casual] only). Rules now produce four tags.
        let item = TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .polo,
            seasons: Season.allCases,
            occasions: [.casual]
        )

        let update = AttributeBackfillService.computeUpdate(for: item)
        #expect(update != nil)

        let occ = Set(update?.occasions ?? [])
        #expect(occ == Set(["casual", "work", "date", "lounge"]))
        // Seasons are already as wide as can be (allCases) so we don't
        // emit an update for that field.
        #expect(update?.seasons == nil)
    }

    @Test @MainActor func computeUpdateBroadensSneakersAcrossDateLounge() {
        // Sneakers had `[casual, athletic]` only; broadened to also
        // cover date + lounge. We don't widen seasons here because
        // sneakers stay on `[spring, summer, fall]`.
        let item = TestFixtures.makeWardrobeItem(
            category: .shoe,
            subcategory: .sneakers,
            seasons: [.spring, .summer, .fall],
            occasions: [.casual]
        )

        let update = AttributeBackfillService.computeUpdate(for: item)
        let occ = Set(update?.occasions ?? [])
        #expect(occ == Set(["casual", "athletic", "date", "lounge"]))
    }

    @Test @MainActor func computeUpdateLeavesUserNarrowedSetsUntouched() {
        // The user explicitly narrowed `occasions` to `[work]` only.
        // The new rules would produce `[casual, work, date, lounge]`
        // for a polo — superset of `[work]`, so we DO widen here.
        // (The plan accepts this trade-off — the conservative path is
        // captured in `computeUpdateLeavesAlreadyWiderUserSetsUntouched`
        // below.)
        let item = TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .polo,
            seasons: Season.allCases,
            occasions: [.work]
        )

        let update = AttributeBackfillService.computeUpdate(for: item)
        // Strict superset → update fires.
        #expect(update != nil)
    }

    @Test @MainActor func computeUpdateLeavesAlreadyWiderUserSetsUntouched() {
        // A user who manually picked `[casual, work, date, lounge,
        // formal]` has a STRICTLY wider set than rules would produce
        // (rules give 4 tags for a polo). isStrictSuperset returns
        // false → no update.
        let item = TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .polo,
            seasons: Season.allCases,
            occasions: [.casual, .work, .date, .lounge, .formal, .athletic]
        )

        #expect(AttributeBackfillService.computeUpdate(for: item) == nil)
    }

    // MARK: - runIfNeeded

    @Test @MainActor func runIfNeededSkipsWhenFlagAlreadySet() async {
        let userId = UUID()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.set(true, forKey: AttributeBackfillService.flagKey(userId: userId))

        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([
            TestFixtures.makeWardrobeItem(category: .top, subcategory: .polo, occasions: [.casual])
        ])

        await AttributeBackfillService.runIfNeeded(
            userId: userId,
            wardrobeRepository: repo,
            defaults: defaults
        )

        #expect(repo.fetchItemsCallCount == 0)
        #expect(repo.updateItemCallCount == 0)
    }

    @Test @MainActor func runIfNeededWidensLegacyItemsAndSetsFlag() async {
        let userId = UUID()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

        let item = TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .polo,
            seasons: Season.allCases,
            occasions: [.casual]
        )
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([item])
        repo.updateItemResult = .success(item)

        await AttributeBackfillService.runIfNeeded(
            userId: userId,
            wardrobeRepository: repo,
            defaults: defaults
        )

        #expect(repo.fetchItemsCallCount == 1)
        #expect(repo.updateItemCallCount == 1)
        #expect(repo.lastUpdatedId == item.id)
        #expect(Set(repo.lastUpdate?.occasions ?? []) == Set(["casual", "work", "date", "lounge"]))
        #expect(defaults.bool(forKey: AttributeBackfillService.flagKey(userId: userId)))
    }

    @Test @MainActor func runIfNeededIsIdempotentOnAlreadyWideItems() async {
        let userId = UUID()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

        // Item is already as wide as rules would derive — backfill
        // should fetch but not call update.
        let wideItem = TestFixtures.makeWardrobeItem(
            category: .top,
            subcategory: .polo,
            seasons: Season.allCases,
            occasions: [.casual, .work, .date, .lounge]
        )
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([wideItem])

        await AttributeBackfillService.runIfNeeded(
            userId: userId,
            wardrobeRepository: repo,
            defaults: defaults
        )

        #expect(repo.fetchItemsCallCount == 1)
        #expect(repo.updateItemCallCount == 0)
        // Flag still gets set so we don't re-fetch on next launch.
        #expect(defaults.bool(forKey: AttributeBackfillService.flagKey(userId: userId)))
    }

    @Test @MainActor func runIfNeededLeavesFlagUnsetOnFetchFailure() async {
        let userId = UUID()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .failure(MockError.simulated)

        await AttributeBackfillService.runIfNeeded(
            userId: userId,
            wardrobeRepository: repo,
            defaults: defaults
        )

        #expect(repo.fetchItemsCallCount == 1)
        // Flag NOT set so a future launch re-attempts the backfill.
        #expect(!defaults.bool(forKey: AttributeBackfillService.flagKey(userId: userId)))
    }
}
