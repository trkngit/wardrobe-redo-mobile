import SnapshotTesting
import SwiftUI
import XCTest
@testable import WardrobeReDo

/// Build 23 — visual regression net for `OutfitCardView`, the card
/// that fills the carousel on the Outfits tab. Catches future
/// theme / spacing / typography regressions before they ship.
///
/// Single-baseline pattern (per `VibeSelectorSnapshotTests`): one
/// fixture-driven snapshot at a representative state. The per-state
/// behavior (worn badge, reactions, score color buckets) is
/// exercised by `OutfitCardViewTests` unit cases.
///
/// ## How to re-record
/// Delete the .1.png under `__Snapshots__/OutfitCardViewSnapshotTests/`
/// and re-run the test. `record: .missing` will write a fresh
/// baseline. Commit the new image alongside any intentional visual
/// change.
@MainActor
final class OutfitCardViewSnapshotTests: XCTestCase {

    func testOutfitCard_defaultState() {
        let host = OutfitCardSnapshotHost()
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 390, height: 360)),
            record: .missing
        )
    }
}

@MainActor
private struct OutfitCardSnapshotHost: View {
    var body: some View {
        OutfitCardView(
            dailyOutfit: TestFixtures.makeDailyOutfit(),
            thumbnailURLs: [:]
        )
        .padding()
    }
}
