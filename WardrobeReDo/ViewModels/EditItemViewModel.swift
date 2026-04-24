import Foundation
import Observation
import os

/// ViewModel for the Edit Item flow. Owns the mutable form state for a
/// single existing `WardrobeItem` and pushes changes back to Supabase
/// via `WardrobeRepositoryProtocol.updateItem(id:updates:)`.
///
/// ## Why separate from AddItemViewModel
/// `AddItemViewModel` orchestrates capture → extraction → multi-garment
/// detection → pre-fill → save — 960 lines of state machine. The Edit
/// flow has none of that: it hydrates six fields from a row, lets the
/// user mutate them, and POSTs the diff. Keeping the surface its own
/// ViewModel keeps both files comprehensible.
///
/// ## Shape of a "save"
/// The VM builds a `WardrobeItemUpdate` containing ONLY the fields the
/// user actually changed. Nil fields are skipped at the Postgres layer
/// (`update ... set` only lists supplied columns), so an edit that
/// toggles one attribute hits a one-column UPDATE rather than writing
/// the whole row back. That also prevents accidental clobbering of
/// server-maintained columns (`wear_count`, `last_worn_at`,
/// `formality_computed`) and of fields this form doesn't expose at all.
///
/// ## Concurrency
/// `@MainActor` because it drives SwiftUI state. All mutations happen
/// on the main actor; the only awaits hop out to the repository actor
/// for the network call.
@MainActor
@Observable
final class EditItemViewModel {

    // MARK: - Form fields

    var category: ClothingCategory
    var subcategory: ClothingSubcategory
    var texture: TextureType?
    var fitAttribute: FitAttribute?
    var selectedSeasons: Set<Season>
    var selectedOccasions: Set<Occasion>

    // MARK: - UI state

    var isSaving: Bool = false
    var didSave: Bool = false
    var errorMessage: String?

    // MARK: - Dependencies + original

    /// The row this VM is editing. We keep a copy of the original so
    /// `buildUpdate()` can diff against it and only send changed columns.
    /// After a successful save the VM replaces this with the server's
    /// returned row, so a second save from the same surface sees the
    /// freshly-persisted baseline — no stale diffs.
    private(set) var original: WardrobeItem
    private let wardrobeRepository: any WardrobeRepositoryProtocol
    private let logger = Logger(subsystem: "com.wardroberedo", category: "EditItem")

    // MARK: - Init

    init(
        item: WardrobeItem,
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository()
    ) {
        self.original = item
        self.wardrobeRepository = wardrobeRepository
        self.category = item.category
        self.subcategory = item.subcategory
        self.texture = item.texture
        self.fitAttribute = item.fitAttribute
        self.selectedSeasons = Set(item.seasons)
        self.selectedOccasions = Set(item.occasions)
    }

    // MARK: - Derived

    var availableSubcategories: [ClothingSubcategory] {
        ClothingSubcategory.subcategories(for: category)
    }

    /// True when at least one form field differs from `original`.
    /// Binds to the Save button's disabled state so users can't fire
    /// an empty UPDATE that would still round-trip through Supabase.
    var hasChanges: Bool {
        buildUpdate() != nil
    }

    // MARK: - Intents

    func onCategoryChanged() {
        let subs = availableSubcategories
        if !subs.contains(subcategory), let first = subs.first {
            subcategory = first
        }
    }

    func save() async {
        guard let update = buildUpdate() else {
            // Nothing to save — treat this as a trivial success so the
            // UI can dismiss without the user getting stuck on a live
            // Save button. Shouldn't happen in practice because the
            // button is gated on `hasChanges`, but a race between that
            // gate and a concurrent `reset()` is possible.
            didSave = true
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            let saved = try await wardrobeRepository.updateItem(id: original.id, updates: update)
            // Replace the baseline so the next edit diffs against the
            // server's view, not our stale copy. Keep the user-visible
            // form values as-is — SwiftUI is re-rendering off them and
            // re-hydrating would flash the field values.
            original = saved
            didSave = true
            logger.info("updateItem.success id=\(self.original.id, privacy: .public)")
        } catch {
            errorMessage = "Couldn't save changes. Try again."
            logger.error("updateItem.failed: \(String(describing: error), privacy: .public)")
        }

        isSaving = false
    }

    // MARK: - Diff construction

    /// Build a `WardrobeItemUpdate` containing only the fields that
    /// differ from `original`. Returns nil when no fields changed —
    /// the caller should skip the network round-trip entirely. Set
    /// semantics for seasons/occasions are compared via the element
    /// set so ordering inside `[Season]`/`[Occasion]` storage arrays
    /// doesn't produce phantom diffs.
    ///
    /// Intentionally `internal` so tests can drive this directly
    /// without reaching through `save()`.
    func buildUpdate() -> WardrobeItemUpdate? {
        var update = WardrobeItemUpdate()
        var changed = false

        if category != original.category {
            update.category = category.rawValue
            changed = true
        }
        if subcategory != original.subcategory {
            update.subcategory = subcategory.rawValue
            changed = true
        }
        if texture != original.texture {
            // `nil` and `.rawValue` are both valid payloads — a user
            // clearing the field should write `null` back to Postgres.
            update.texture = texture?.rawValue
            changed = true
        }
        if fitAttribute != original.fitAttribute {
            update.fitAttribute = fitAttribute?.rawValue
            changed = true
        }
        if selectedSeasons != Set(original.seasons) {
            update.seasons = Array(selectedSeasons).map(\.rawValue)
            changed = true
        }
        if selectedOccasions != Set(original.occasions) {
            update.occasions = Array(selectedOccasions).map(\.rawValue)
            changed = true
        }

        return changed ? update : nil
    }
}

// MARK: - Equatable for WardrobeItemUpdate (tests only)

/// Value-comparison for `WardrobeItemUpdate` so tests can assert "we
/// built exactly this payload." Out of the main struct because the
/// production code only ever compares against nil (`buildUpdate()`
/// returns nil on no-change) — a free Equatable conformance would
/// widen the surface area and invite someone to diff two updates in
/// app code, which isn't a meaningful operation.
extension WardrobeItemUpdate: Equatable {
    public static func == (lhs: WardrobeItemUpdate, rhs: WardrobeItemUpdate) -> Bool {
        lhs.category == rhs.category
            && lhs.subcategory == rhs.subcategory
            && lhs.texture == rhs.texture
            && lhs.fitAttribute == rhs.fitAttribute
            && lhs.seasons == rhs.seasons
            && lhs.occasions == rhs.occasions
            && lhs.isArchived == rhs.isArchived
    }
}
