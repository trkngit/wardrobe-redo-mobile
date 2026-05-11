import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - OccasionMemory (build 8)
//
// UserDefaults-backed per-tab memory of the user's most-recent
// occasion pick. Tests use the real `UserDefaults.standard` and
// clean up the keys they touch; we deliberately don't introduce
// a UserDefaults injection point here because the surface area
// is too small to justify it, and the cleanup-after pattern is
// established in `ProfileDefaultVibeTests`.

private enum OccasionMemoryTestSupport {
    static let outfitsKey = "wardrobe.lastOccasion.outfits"
    static let matchKey = "wardrobe.lastOccasion.match"

    @MainActor
    static func clear() {
        UserDefaults.standard.removeObject(forKey: outfitsKey)
        UserDefaults.standard.removeObject(forKey: matchKey)
    }
}

@Test @MainActor func occasionMemoryReturnsCasualOnFirstLaunch() {
    OccasionMemoryTestSupport.clear()
    // No prior write — both surfaces fall back to `.casual`.
    // That's the cold-start state the rest of the app already
    // shows on the picker, so the seeded VM matches the visible
    // chip selection.
    #expect(OccasionMemory.outfitsLastOccasion() == .casual)
    #expect(OccasionMemory.matchLastOccasion() == .casual)
}

@Test @MainActor func occasionMemoryRoundtripsPerSurface() {
    OccasionMemoryTestSupport.clear()
    defer { OccasionMemoryTestSupport.clear() }

    OccasionMemory.setOutfitsLastOccasion(.date)
    OccasionMemory.setMatchLastOccasion(.work)

    #expect(OccasionMemory.outfitsLastOccasion() == .date)
    #expect(OccasionMemory.matchLastOccasion() == .work)
}

@Test @MainActor func occasionMemoryPerSurfaceKeysAreIndependent() {
    // Writing to one surface must NOT bleed into the other —
    // the whole point of the per-tab split is "match-flow
    // 'work' doesn't blow away outfits-flow 'date'".
    OccasionMemoryTestSupport.clear()
    defer { OccasionMemoryTestSupport.clear() }

    OccasionMemory.setOutfitsLastOccasion(.athletic)
    #expect(OccasionMemory.matchLastOccasion() == .casual)

    OccasionMemory.setMatchLastOccasion(.formal)
    #expect(OccasionMemory.outfitsLastOccasion() == .athletic)
}

@Test @MainActor func occasionMemoryFallsBackOnUnparseableRawValue() {
    // Defensive: if a future version renames an Occasion enum
    // case, the stored rawValue won't decode — should silently
    // fall back to `.casual` instead of crashing.
    UserDefaults.standard.set("nonexistent_occasion", forKey: OccasionMemoryTestSupport.outfitsKey)
    defer { OccasionMemoryTestSupport.clear() }

    #expect(OccasionMemory.outfitsLastOccasion() == .casual)
}
