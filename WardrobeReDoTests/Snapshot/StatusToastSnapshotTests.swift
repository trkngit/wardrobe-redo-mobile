import SnapshotTesting
import SwiftUI
import XCTest
@testable import WardrobeReDo

/// Build 23 — visual regression net for `StatusToast`, the
/// confirmation pill that appears after a debounced regeneration
/// (Outfits + Match tabs). Touches the StatusToast component's
/// capsule shape, shadow, icon + label layout, and theme color
/// resolution.
///
/// Pinned at a fixed width that matches the toast's typical
/// rendering on iPhone-class devices. Layout doesn't depend on
/// surrounding content because the toast is a self-contained pill.
@MainActor
final class StatusToastSnapshotTests: XCTestCase {

    func testStatusToast_shortMessage() {
        let host = StatusToastSnapshotHost(
            message: "Updated for Casual · Balanced"
        )
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 390, height: 100)),
            record: .missing
        )
    }
}

@MainActor
private struct StatusToastSnapshotHost: View {
    let message: String

    var body: some View {
        StatusToast(message: message)
            .padding()
    }
}
