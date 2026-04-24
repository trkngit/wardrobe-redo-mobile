import SnapshotTesting
import SwiftUI
import XCTest
@testable import WardrobeReDo

/// Baseline snapshot coverage for `ItemFormView` in its default
/// (no-texture / no-fit / no-seasons / no-occasions) state.
///
/// ## Why this exists
/// `ItemFormView` is the shared layer between `AddItemView` and
/// `EditItemView`; a drift in its empty state would ripple through both
/// surfaces silently (picker defaults, section header spacing,
/// sparkle-badge hook). A single baseline snapshot catches visual
/// regressions before they hit either caller.
///
/// ## Deliberately one test
/// This is a baseline — it proves the plumbing works end-to-end. Adding
/// populated-state, auto-detected, and error-state variants is a v1.2
/// follow-up; do NOT expand this suite to every permutation before the
/// recording / diffing flow is battle-tested against Swift 6 strict
/// concurrency and the self-hosted CI runner.
///
/// ## How to re-record
/// If an intentional UI change invalidates the baseline, temporarily flip
/// the `record:` argument to `.all`, run the test locally, verify the
/// new `.1.png` renders correctly, flip it back to `.missing`, and
/// commit both the code change and the updated `__Snapshots__` file.
@MainActor
final class ItemFormViewSnapshotTests: XCTestCase {

    func testItemFormView_defaultState() {
        let host = ItemFormSnapshotHost()
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 390, height: 844)),
            record: .missing
        )
    }
}

/// Wraps `ItemFormView` with local `@State` bindings so the snapshot
/// engine can render a self-contained view hierarchy. The wrapper mirrors
/// the initial state the Add flow lands on before the user touches any
/// field: category `.top`, first matching subcategory, and no optional
/// attribute filled in.
@MainActor
private struct ItemFormSnapshotHost: View {
    @State private var category: ClothingCategory = .top
    @State private var subcategory: ClothingSubcategory =
        ClothingSubcategory.subcategories(for: .top).first ?? .tshirt
    @State private var texture: TextureType?
    @State private var fitAttribute: FitAttribute?
    @State private var selectedSeasons: Set<Season> = []
    @State private var selectedOccasions: Set<Occasion> = []

    var body: some View {
        ItemFormView(
            category: $category,
            subcategory: $subcategory,
            texture: $texture,
            fitAttribute: $fitAttribute,
            selectedSeasons: $selectedSeasons,
            selectedOccasions: $selectedOccasions,
            availableSubcategories: ClothingSubcategory.subcategories(for: category)
        )
        .padding()
    }
}
