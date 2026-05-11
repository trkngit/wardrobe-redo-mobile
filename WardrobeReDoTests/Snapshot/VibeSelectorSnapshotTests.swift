import SnapshotTesting
import SwiftUI
import XCTest
@testable import WardrobeReDo

/// Baseline snapshot coverage for `VibeSelector` — the build-6
/// 5-pill control that drives outfit-generation strictness. We
/// snapshot one stop (`.balanced`, the default) so a future
/// theme / spacing / typography regression on the shared control
/// is caught before it ships to both the Outfits and Match
/// surfaces.
///
/// Follows the same single-baseline pattern as
/// `ItemFormViewSnapshotTests` — do not expand to every stop
/// before the recording / diffing flow is battle-tested. The
/// per-stop label + active-state logic is exercised by the
/// existing `VibePresetTests` unit suite.
///
/// ## How to re-record
/// Flip `record:` from `.missing` to `.all`, run the test locally,
/// verify the new `.1.png` renders correctly, flip back to
/// `.missing`, and commit both the code change and the updated
/// `__Snapshots__` file.
@MainActor
final class VibeSelectorSnapshotTests: XCTestCase {

    func testVibeSelector_balancedState() {
        let host = VibeSelectorSnapshotHost(initial: .balanced)
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 390, height: 120)),
            record: .missing
        )
    }
}

@MainActor
private struct VibeSelectorSnapshotHost: View {
    @State private var vibe: VibeStop

    init(initial: VibeStop) {
        self._vibe = State(initialValue: initial)
    }

    var body: some View {
        VibeSelector(vibe: $vibe)
            .padding()
    }
}
