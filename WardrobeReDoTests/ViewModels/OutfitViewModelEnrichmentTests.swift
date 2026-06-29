import Foundation
import Testing
@testable import WardrobeReDo

/// Build 52 — Phase 3 fit enrichment. The Outfits feed surfaces a one-tap
/// prompt for an item whose fit Fast Add auto-defaulted to `.regular` and
/// never confirmed (no `"fit"` provenance); answering writes the attribute.
///
/// `.serialized` because candidate detection is gated on
/// `FeatureFlags.isFastAddEnabled` (UserDefaults-backed global).
@MainActor
@Suite("OutfitViewModel.fitEnrichment", .serialized)
struct OutfitViewModelEnrichmentTests {

    private func makeVM(_ repo: MockWardrobeRepository) -> OutfitViewModel {
        OutfitViewModel(wardrobeRepository: repo)
    }

    @Test func refreshPicksRegularFitItemWithNoFitProvenance() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()             // Fast Add default on
        defer { FeatureFlags.resetAll() }

        let candidate = TestFixtures.makeWardrobeItem(fitAttribute: .regular, detectedAttributes: [:])
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([candidate])
        let vm = makeVM(repo)

        await vm.refreshFitEnrichment(userId: UUID())

        #expect(vm.fitEnrichmentCandidate?.id == candidate.id)
    }

    @Test func refreshSkipsNonRegularFitAndConfirmedFit() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let slim = TestFixtures.makeWardrobeItem(fitAttribute: .slim)                 // not .regular
        let confirmed = TestFixtures.makeWardrobeItem(
            fitAttribute: .regular,
            detectedAttributes: ["fit": "user"]                                        // already confirmed
        )
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([slim, confirmed])
        let vm = makeVM(repo)

        await vm.refreshFitEnrichment(userId: UUID())

        #expect(vm.fitEnrichmentCandidate == nil, "no un-confirmed .regular-fit item → no prompt")
    }

    @Test func applyFitWritesAttributeAndClearsPrompt() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let candidate = TestFixtures.makeWardrobeItem(fitAttribute: .regular)
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([candidate])
        let vm = makeVM(repo)
        await vm.refreshFitEnrichment(userId: UUID())
        #expect(vm.fitEnrichmentCandidate != nil)   // precondition

        await vm.applyFitEnrichment(.slim)

        #expect(repo.updateItemCallCount == 1)
        #expect(repo.lastUpdatedId == candidate.id)
        #expect(repo.lastUpdate?.fitAttribute == FitAttribute.slim.rawValue)
        #expect(vm.fitEnrichmentCandidate == nil, "prompt clears after answering")
    }

    @Test func dismissExcludesItemFromNextRefresh() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        defer { FeatureFlags.resetAll() }

        let candidate = TestFixtures.makeWardrobeItem(fitAttribute: .regular)
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([candidate])
        let vm = makeVM(repo)
        await vm.refreshFitEnrichment(userId: UUID())
        #expect(vm.fitEnrichmentCandidate != nil)

        vm.dismissFitEnrichment()
        #expect(vm.fitEnrichmentCandidate == nil)

        // The item is still in the wardrobe, but it's been dismissed.
        await vm.refreshFitEnrichment(userId: UUID())
        #expect(vm.fitEnrichmentCandidate == nil, "a dismissed item is not re-surfaced this session")
    }

    @Test func noPromptWhenFastAddOff() async {
        await FeatureFlagTestIsolation.shared.acquire()
        defer { Task { await FeatureFlagTestIsolation.shared.release() } }
        FeatureFlags.resetAll()
        FeatureFlags.isFastAddEnabled = false
        defer { FeatureFlags.resetAll() }

        let candidate = TestFixtures.makeWardrobeItem(fitAttribute: .regular)
        let repo = MockWardrobeRepository()
        repo.fetchItemsResult = .success([candidate])
        let vm = makeVM(repo)

        await vm.refreshFitEnrichment(userId: UUID())

        #expect(vm.fitEnrichmentCandidate == nil, "enrichment is gated on Fast Add")
    }
}
