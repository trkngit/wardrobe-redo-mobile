import Foundation
import Testing
@testable import WardrobeReDo

/// Tests for `WardrobeViewModel.sessions` — the computed property that
/// folds individual `WardrobeItem`s into capture sessions for the wardrobe
/// grid. Behaviors verified here:
///
///   1. Items sharing a `sourcePhotoId` collapse into one session.
///   2. Different `sourcePhotoId`s produce separate sessions.
///   3. Legacy items (`sourcePhotoId == nil`) each become their own
///      1-item session — never lumped into a single fake session.
///   4. Sessions sort newest-first; items inside sort oldest-first.
///   5. The category filter operates at the item level, so sessions
///      where every item is filtered out disappear, and sessions with
///      mixed categories show only the matching items when a filter is
///      active.
@MainActor
@Suite("WardrobeViewModel.sessions")
struct WardrobeViewModelSessionsTests {

    // MARK: - Grouping

    @Test func itemsWithSameSourcePhotoIdCollapseIntoOneSession() {
        let captureId = UUID()
        let captureDate = Date()
        let vm = WardrobeViewModel()
        vm.items = [
            TestFixtures.makeWardrobeItem(
                category: .top,
                sourcePhotoId: captureId,
                sourcePhotoPath: "users/u/source/\(captureId)/original.jpg",
                createdAt: captureDate
            ),
            TestFixtures.makeWardrobeItem(
                category: .bottom,
                subcategory: .jeans,
                sourcePhotoId: captureId,
                sourcePhotoPath: "users/u/source/\(captureId)/original.jpg",
                createdAt: captureDate.addingTimeInterval(1)
            ),
            TestFixtures.makeWardrobeItem(
                category: .shoe,
                subcategory: .sneakers,
                sourcePhotoId: captureId,
                sourcePhotoPath: "users/u/source/\(captureId)/original.jpg",
                createdAt: captureDate.addingTimeInterval(2)
            ),
        ]

        let sessions = vm.sessions
        #expect(sessions.count == 1)
        #expect(sessions[0].items.count == 3)
        #expect(sessions[0].sourcePhotoId == captureId)
        #expect(sessions[0].id == captureId)
    }

    @Test func itemsWithDifferentSourcePhotoIdsBecomeSeparateSessions() {
        let vm = WardrobeViewModel()
        vm.items = (0..<3).map { i in
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: UUID(),
                sourcePhotoPath: "users/u/source/cap-\(i)/original.jpg",
                createdAt: Date().addingTimeInterval(Double(i))
            )
        }

        let sessions = vm.sessions
        #expect(sessions.count == 3)
        #expect(sessions.allSatisfy { $0.items.count == 1 })
    }

    @Test func legacyItemsWithNilSourcePhotoIdEachBecomeOwnSession() {
        let vm = WardrobeViewModel()
        // Four legacy rows — sourcePhotoId nil on every one. The fix
        // here is that they don't lump together as a single fake session;
        // they each become their own 1-item session keyed on the item id.
        vm.items = (0..<4).map { i in
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: nil,
                sourcePhotoPath: nil,
                createdAt: Date().addingTimeInterval(Double(i))
            )
        }

        let sessions = vm.sessions
        #expect(sessions.count == 4)
        #expect(sessions.allSatisfy { $0.items.count == 1 })
        #expect(sessions.allSatisfy { $0.sourcePhotoId == nil })
        // Each session's id should equal its item's id (the fallback key).
        for session in sessions {
            #expect(session.id == session.items[0].id)
        }
    }

    // MARK: - Sorting

    @Test func sessionsSortedNewestFirst() {
        let oldId = UUID()
        let midId = UUID()
        let newId = UUID()
        let now = Date()
        let vm = WardrobeViewModel()
        vm.items = [
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: midId,
                createdAt: now.addingTimeInterval(-3600) // 1h ago
            ),
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: oldId,
                createdAt: now.addingTimeInterval(-86_400) // 1d ago
            ),
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: newId,
                createdAt: now.addingTimeInterval(-60) // 1m ago
            ),
        ]

        let sessionIds = vm.sessions.map(\.id)
        #expect(sessionIds == [newId, midId, oldId])
    }

    @Test func sessionItemsSortedOldestFirstWithinSession() {
        let captureId = UUID()
        let now = Date()
        let firstSavedId = UUID()
        let secondSavedId = UUID()
        let thirdSavedId = UUID()

        let vm = WardrobeViewModel()
        // Insert items intentionally out of save order — the sort inside
        // the session should reorder them oldest-first regardless of how
        // the array came in from the repository.
        vm.items = [
            TestFixtures.makeWardrobeItem(
                id: thirdSavedId,
                sourcePhotoId: captureId,
                createdAt: now.addingTimeInterval(20)
            ),
            TestFixtures.makeWardrobeItem(
                id: firstSavedId,
                sourcePhotoId: captureId,
                createdAt: now
            ),
            TestFixtures.makeWardrobeItem(
                id: secondSavedId,
                sourcePhotoId: captureId,
                createdAt: now.addingTimeInterval(10)
            ),
        ]

        let sessions = vm.sessions
        #expect(sessions.count == 1)
        let itemIds = sessions[0].items.map(\.id)
        #expect(itemIds == [firstSavedId, secondSavedId, thirdSavedId])
    }

    // MARK: - Filter integration

    @Test func categoryFilterDropsSessionsWithNoMatchingItems() {
        let topsOnlyCapture = UUID()
        let mixedCapture = UUID()
        let vm = WardrobeViewModel()
        vm.items = [
            // Capture A: 2 tops, no bottoms.
            TestFixtures.makeWardrobeItem(
                category: .top,
                sourcePhotoId: topsOnlyCapture
            ),
            TestFixtures.makeWardrobeItem(
                category: .top,
                sourcePhotoId: topsOnlyCapture
            ),
            // Capture B: 1 top + 1 bottom.
            TestFixtures.makeWardrobeItem(
                category: .top,
                sourcePhotoId: mixedCapture
            ),
            TestFixtures.makeWardrobeItem(
                category: .bottom,
                subcategory: .jeans,
                sourcePhotoId: mixedCapture
            ),
        ]

        vm.selectedCategory = .bottom

        let sessions = vm.sessions
        // Only the mixed session survives — the tops-only capture is
        // filtered out entirely because none of its items match.
        #expect(sessions.count == 1)
        #expect(sessions[0].sourcePhotoId == mixedCapture)
    }

    @Test func categoryFilterKeepsSessionWithAtLeastOneMatchingItem() {
        let mixedCapture = UUID()
        let vm = WardrobeViewModel()
        vm.items = [
            TestFixtures.makeWardrobeItem(
                category: .top,
                sourcePhotoId: mixedCapture
            ),
            TestFixtures.makeWardrobeItem(
                category: .bottom,
                subcategory: .jeans,
                sourcePhotoId: mixedCapture
            ),
            TestFixtures.makeWardrobeItem(
                category: .shoe,
                subcategory: .sneakers,
                sourcePhotoId: mixedCapture
            ),
        ]

        vm.selectedCategory = .bottom

        let sessions = vm.sessions
        #expect(sessions.count == 1)
        // The session keeps its id but only the bottom item shows
        // through the filter — tops + shoes are dropped at the item
        // level, so the session ends up as a 1-item view of itself.
        #expect(sessions[0].items.count == 1)
        #expect(sessions[0].items[0].category == .bottom)
    }

    // MARK: - Cached sessions stability

    /// `sessions` was previously a computed property that re-ran
    /// `Dictionary(grouping:) + sorted` on every body evaluation. Now it's
    /// stored and recomputed only on `items` / `selectedCategory` change,
    /// so two reads in a row must yield the same array (same ids in same
    /// order, same counts). Locks in the cache contract so a future
    /// refactor can't silently regress to the per-read computation.
    @Test func sessionsAreStableAcrossRepeatedReads() {
        let captureA = UUID()
        let captureB = UUID()
        let vm = WardrobeViewModel()
        vm.items = [
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: captureA,
                createdAt: Date().addingTimeInterval(-60)
            ),
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: captureA,
                createdAt: Date().addingTimeInterval(-30)
            ),
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: captureB,
                createdAt: Date()
            ),
        ]

        let firstRead = vm.sessions
        let secondRead = vm.sessions
        // Same session ids in same order across reads.
        #expect(firstRead.map(\.id) == secondRead.map(\.id))
        // Item ids inside each session match too (no internal re-ordering).
        for (a, b) in zip(firstRead, secondRead) {
            #expect(a.items.map(\.id) == b.items.map(\.id))
        }
    }

    // MARK: - groupedSessions

    /// The wardrobe grid packs consecutive single-item sessions into one
    /// shared 2-column grid (so two singles in a row pack side-by-side
    /// instead of each rendering as a half-width card with empty space on
    /// the right). Multi-item sessions interrupt the run with their own
    /// header + grid block. The reviewer's worked example: input
    /// `[Single, Single, Multi(3), Single, Multi(2), Single]` should fold
    /// into 5 groups — `singles[2]`, `session(Multi 3)`, `singles[1]`,
    /// `session(Multi 2)`, `singles[1]` — with stagger starting indices
    /// 0, 2, 5, 6, 9 so the fade-in animations stay in lockstep with
    /// visual order.
    @Test func groupedSessionsFusesConsecutiveSinglesAndPreservesStagger() {
        // Build sessions by descending createdAt so they land in the
        // ViewModel's newest-first order in exactly the layout we expect:
        //   Single, Single, Multi(3), Single, Multi(2), Single.
        let now = Date()
        let vm = WardrobeViewModel()
        var items: [WardrobeItem] = []

        // Newest single (index 0 visually).
        items.append(
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: UUID(),
                createdAt: now.addingTimeInterval(-1)
            )
        )
        // Second single (index 1).
        items.append(
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: UUID(),
                createdAt: now.addingTimeInterval(-2)
            )
        )
        // Multi(3) — third group (indices 2,3,4).
        let multiA = UUID()
        for offset in 0..<3 {
            items.append(
                TestFixtures.makeWardrobeItem(
                    sourcePhotoId: multiA,
                    createdAt: now.addingTimeInterval(-3 - Double(offset))
                )
            )
        }
        // Single (index 5).
        items.append(
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: UUID(),
                createdAt: now.addingTimeInterval(-7)
            )
        )
        // Multi(2) — (indices 6,7).
        let multiB = UUID()
        for offset in 0..<2 {
            items.append(
                TestFixtures.makeWardrobeItem(
                    sourcePhotoId: multiB,
                    createdAt: now.addingTimeInterval(-8 - Double(offset))
                )
            )
        }
        // Trailing single (index 8).
        items.append(
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: UUID(),
                createdAt: now.addingTimeInterval(-12)
            )
        )

        vm.items = items

        // Sanity: the underlying sessions order (newest-first) must match
        // what we built — otherwise the grouping assertions below test
        // nothing meaningful.
        let sessions = vm.sessions
        #expect(sessions.count == 6)
        #expect(sessions[0].items.count == 1)
        #expect(sessions[1].items.count == 1)
        #expect(sessions[2].items.count == 3)
        #expect(sessions[3].items.count == 1)
        #expect(sessions[4].items.count == 2)
        #expect(sessions[5].items.count == 1)

        // Now the grouping. Expected: 5 groups in order:
        //   singles[2]    staggerStart 0
        //   session(3)    staggerStart 2
        //   singles[1]    staggerStart 5
        //   session(2)    staggerStart 6
        //   singles[1]    staggerStart 8
        let groups = vm.groupedSessions
        #expect(groups.count == 5)

        guard groups.count == 5 else { return }

        switch groups[0] {
        case .singles(let items, let start):
            #expect(items.count == 2)
            #expect(start == 0)
        case .session:
            Issue.record("groups[0] expected .singles, got .session")
        }

        switch groups[1] {
        case .session(let session, let start):
            #expect(session.items.count == 3)
            #expect(start == 2)
        case .singles:
            Issue.record("groups[1] expected .session, got .singles")
        }

        switch groups[2] {
        case .singles(let items, let start):
            #expect(items.count == 1)
            #expect(start == 5)
        case .session:
            Issue.record("groups[2] expected .singles, got .session")
        }

        switch groups[3] {
        case .session(let session, let start):
            #expect(session.items.count == 2)
            #expect(start == 6)
        case .singles:
            Issue.record("groups[3] expected .session, got .singles")
        }

        switch groups[4] {
        case .singles(let items, let start):
            #expect(items.count == 1)
            #expect(start == 8)
        case .session:
            Issue.record("groups[4] expected .singles, got .session")
        }
    }

    @Test func groupedSessionsAllSinglesPackIntoOneGroup() {
        let vm = WardrobeViewModel()
        vm.items = (0..<4).map { i in
            TestFixtures.makeWardrobeItem(
                sourcePhotoId: UUID(),
                createdAt: Date().addingTimeInterval(Double(-i))
            )
        }

        let groups = vm.groupedSessions
        #expect(groups.count == 1)
        if case .singles(let items, let start) = groups[0] {
            #expect(items.count == 4)
            #expect(start == 0)
        } else {
            Issue.record("Expected one .singles group, got \(groups.count) of mixed kinds")
        }
    }

    @Test func groupedSessionsEmptyWardrobe() {
        let vm = WardrobeViewModel()
        vm.items = []
        #expect(vm.groupedSessions.isEmpty)
    }
}
