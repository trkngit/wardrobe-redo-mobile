import Foundation
import Observation

/// One "capture" worth of saved garments. Items extracted from the same
/// source photo (same `sourcePhotoId`) collapse into a single session so
/// the wardrobe grid doesn't show 4 visually identical cards when a user
/// multi-picks 4 garments from one mirror selfie. Legacy items where
/// `sourcePhotoId == nil` each become their own 1-item session keyed on
/// `item.id` — never lumped together as a fake "Untitled" group.
struct WardrobeSession: Identifiable, Sendable {
    /// `sourcePhotoId` when present; otherwise the lone item's id. Drives
    /// `Identifiable` for the SwiftUI `ForEach`.
    let id: UUID
    /// The shared `sourcePhotoId` for the group. Nil only when the
    /// underlying items lack one (legacy / single-item captures pre-00008).
    let sourcePhotoId: UUID?
    /// Storage path to the unmasked source photo for the group. Nil for
    /// legacy items pre-00008. UI uses this to render the session header
    /// thumb; nil falls back to a placeholder icon.
    let sourcePhotoPath: String?
    /// Items in the session, sorted oldest-first so the order in the grid
    /// matches the order they were saved during the multi-garment loop.
    let items: [WardrobeItem]
    /// Earliest `createdAt` across the items — used to sort sessions
    /// newest-first at the wardrobe level.
    let createdAt: Date
}

/// Build 11 — wardrobe sort options. `.newest` preserves the
/// capture-session grouping (default). Wear-count sorts flatten
/// the grid into a 2-column singles run because "most worn"
/// cuts across sessions and the session header would be
/// meaningless. Display copy is the visible label in the SwiftUI
/// `Menu`.
enum SortOrder: String, CaseIterable, Sendable {
    case newest
    case mostWorn
    case leastWorn

    var displayName: String {
        switch self {
        case .newest:    return "Newest"
        case .mostWorn:  return "Most worn"
        case .leastWorn: return "Least worn"
        }
    }

    /// Build 17 — localized form for the WardrobeGridView sort menu.
    var localizedName: LocalizedStringResource {
        switch self {
        case .newest:    LocalizedStringResource("Newest")
        case .mostWorn:  LocalizedStringResource("Most worn")
        case .leastWorn: LocalizedStringResource("Least worn")
        }
    }

    /// SF Symbol that matches the visual semantic of each option.
    var iconName: String {
        switch self {
        case .newest:    return "clock"
        case .mostWorn:  return "flame"
        case .leastWorn: return "sparkles"
        }
    }
}

/// One renderable block in the wardrobe grid. Consecutive single-item
/// sessions fuse into a `.singles` block so they pack into the 2-column
/// grid together; multi-item sessions get their own `.session` block with
/// a header. `staggerStart` is the cumulative item index across the whole
/// list, so `staggeredFadeIn` animation timing stays consistent regardless
/// of how the runs split.
enum SessionGroup: Identifiable, Sendable {
    case singles(items: [WardrobeItem], staggerStart: Int)
    case session(WardrobeSession, staggerStart: Int)

    /// Stable id for SwiftUI `ForEach`. For `.singles`, the first item's
    /// id is enough — a run never overlaps with another run, and the
    /// first item's id changes only when the group's contents change.
    /// For `.session`, the session's own id (sourcePhotoId or lone item id).
    var id: UUID {
        switch self {
        case .singles(let items, _):
            return items.first?.id ?? UUID()
        case .session(let session, _):
            return session.id
        }
    }
}

@MainActor
@Observable
final class WardrobeViewModel {
    // MARK: - State

    var items: [WardrobeItem] = [] {
        didSet { recomputeSessions() }
    }
    var selectedCategory: ClothingCategory? {
        didSet { recomputeSessions() }
    }
    /// Build 9 — free-text wardrobe search. Filters by substring
    /// across the item's category + subcategory display names and
    /// the texture name. Combined with `selectedCategory`: chip
    /// narrows by category, query narrows further by name.
    ///
    /// Empty / whitespace strings disable the filter (same as
    /// "no query"), so clearing the field via the trailing X
    /// returns to the category-only view without a reload.
    var searchQuery: String = "" {
        didSet { recomputeSessions() }
    }
    /// Build 11 — sort order across the wardrobe grid. `.newest`
    /// keeps the capture-session grouping (a multi-garment selfie
    /// stays bundled). Wear-count sorts flatten sessions into a
    /// single grid because "most worn" cuts across captures and
    /// the session header would be meaningless for it. Default
    /// is `.newest` so the wardrobe behavior pre-Build 11 is
    /// preserved for everyone who never opens the sort menu.
    var sortOrder: SortOrder = .newest {
        didSet { recomputeSessions() }
    }
    var isLoading = false
    var errorMessage: String?
    var showAddItem = false

    /// Filtered items grouped by `sourcePhotoId` into capture sessions.
    /// Legacy items with `sourcePhotoId == nil` each become a 1-item
    /// session keyed on the item's own id (so a wardrobe full of legacy
    /// rows doesn't render as one giant fake "session"). Sessions are
    /// sorted newest-first; items inside a session are sorted oldest-first
    /// to preserve the order the user saved them during the multi-garment
    /// loop. A category filter that drops every item in a session also
    /// drops the session itself.
    ///
    /// Cached as a stored property and recomputed only when `items` or
    /// `selectedCategory` change — the previous computed-property
    /// implementation re-ran `Dictionary(grouping:) + sort` on every
    /// SwiftUI body evaluation, which got expensive once a wardrobe had
    /// dozens of sessions.
    private(set) var sessions: [WardrobeSession] = []

    // MARK: - Dependencies

    private let wardrobeRepository: any WardrobeRepositoryProtocol
    private let imageService: any ImageServiceProtocol

    init(
        wardrobeRepository: any WardrobeRepositoryProtocol = WardrobeRepository(),
        imageService: any ImageServiceProtocol = ImageService()
    ) {
        self.wardrobeRepository = wardrobeRepository
        self.imageService = imageService
    }

    // MARK: - Computed

    var filteredItems: [WardrobeItem] {
        let categoryFiltered: [WardrobeItem] = {
            guard let category = selectedCategory else { return items }
            return items.filter { $0.category == category }
        }()

        // Build 9 — substring match across the strings the user
        // sees on the card: subcategory ("Sneakers"), category
        // ("Shoe"), and texture ("Denim"). Case-insensitive. An
        // empty / whitespace query is a no-op so the field can
        // safely sit above the chip row without changing default
        // behavior.
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return categoryFiltered }
        let needle = trimmed.lowercased()
        return categoryFiltered.filter { item in
            let haystack = [
                item.subcategory.displayName.lowercased(),
                item.category.displayName.lowercased(),
                item.texture?.displayName.lowercased() ?? ""
            ].joined(separator: " ")
            return haystack.contains(needle)
        }
    }

    private func recomputeSessions() {
        switch sortOrder {
        case .newest:
            recomputeSessionsBySession()
        case .mostWorn, .leastWorn:
            recomputeSessionsFlat()
        }
    }

    /// Default behavior: items grouped into capture sessions,
    /// sessions sorted newest-first. Preserves the visual story
    /// of "this selfie produced 3 garments".
    private func recomputeSessionsBySession() {
        let grouped = Dictionary(grouping: filteredItems) { item in
            item.sourcePhotoId ?? item.id
        }

        sessions = grouped.map { (key, groupItems) in
            let sortedItems = groupItems.sorted { $0.createdAt < $1.createdAt }
            let first = sortedItems.first
            return WardrobeSession(
                id: key,
                sourcePhotoId: first?.sourcePhotoId,
                sourcePhotoPath: first?.sourcePhotoPath,
                items: sortedItems,
                createdAt: sortedItems.first?.createdAt ?? Date()
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Build 11 — flat 2-column layout for wear-count sorts. The
    /// session metadata is irrelevant when ordering across
    /// captures by wear count, so every item becomes a one-item
    /// "session" and `groupedSessions` fuses them into a single
    /// `.singles` run. Tie-break on `createdAt` desc so two items
    /// with the same wear count display newest-first within that
    /// tier — gives a stable, predictable order.
    private func recomputeSessionsFlat() {
        let sortedItems: [WardrobeItem] = {
            switch sortOrder {
            case .mostWorn:
                return filteredItems.sorted { lhs, rhs in
                    if lhs.wearCount != rhs.wearCount {
                        return lhs.wearCount > rhs.wearCount
                    }
                    return lhs.createdAt > rhs.createdAt
                }
            case .leastWorn:
                return filteredItems.sorted { lhs, rhs in
                    if lhs.wearCount != rhs.wearCount {
                        return lhs.wearCount < rhs.wearCount
                    }
                    return lhs.createdAt > rhs.createdAt
                }
            case .newest:
                return filteredItems  // unreachable, handled in the dispatch
            }
        }()

        sessions = sortedItems.map { item in
            WardrobeSession(
                id: item.id,
                sourcePhotoId: nil,
                sourcePhotoPath: nil,
                items: [item],
                createdAt: item.createdAt
            )
        }
    }

    /// `sessions` collapsed into renderable groups. Consecutive single-item
    /// sessions fuse into one `.singles` block so the wardrobe grid keeps its
    /// 2-column packing — without this, two singles in a row each rendered as
    /// a half-width card with empty space on the right. Multi-item sessions
    /// interrupt the run with their own `.session` block. The
    /// `staggerStart` carried on each group preserves the original cumulative
    /// item index so `staggeredFadeIn` animations stay in lockstep with the
    /// visual order.
    var groupedSessions: [SessionGroup] {
        var result: [SessionGroup] = []
        var pendingSingles: [WardrobeItem] = []
        var pendingStart = 0
        var stagger = 0
        for session in sessions {
            if session.items.count == 1 {
                if pendingSingles.isEmpty { pendingStart = stagger }
                pendingSingles.append(session.items[0])
                stagger += 1
            } else {
                if !pendingSingles.isEmpty {
                    result.append(.singles(items: pendingSingles, staggerStart: pendingStart))
                    pendingSingles = []
                }
                result.append(.session(session, staggerStart: stagger))
                stagger += session.items.count
            }
        }
        if !pendingSingles.isEmpty {
            result.append(.singles(items: pendingSingles, staggerStart: pendingStart))
        }
        return result
    }

    var itemCountText: String {
        let count = filteredItems.count
        if let category = selectedCategory {
            // Build 17 — pull localized category name so the count
            // line ("3 Tops" / "3 Üst Giyim") matches the surrounding
            // UI's language.
            let name = String(localized: category.localizedName)
            return "\(count) \(name)"
        }
        // Build 17 — separate singular vs plural keys keep Turkish
        // pluralization clean ("1 ürün" / "5 ürün" — Turkish doesn't
        // pluralize counted nouns the way English does, but we keep
        // the key shape for symmetry).
        if count == 1 {
            return String(localized: "1 item")
        }
        return String(localized: "\(count) items")
    }

    var isEmpty: Bool {
        filteredItems.isEmpty && !isLoading
    }

    // MARK: - Actions

    func loadItems(userId: UUID) async {
        isLoading = true
        errorMessage = nil

        do {
            items = try await wardrobeRepository.fetchItems(userId: userId)
        } catch {
            errorMessage = "Couldn't load your wardrobe. Pull to refresh."
        }

        isLoading = false
    }

    func selectCategory(_ category: ClothingCategory?) {
        selectedCategory = selectedCategory == category ? nil : category
    }

    func archiveItem(_ item: WardrobeItem) async {
        do {
            try await wardrobeRepository.archiveItem(id: item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = "Couldn't archive item."
        }
    }

    func deleteItem(_ item: WardrobeItem, userId: UUID) async {
        do {
            // Delete from DB first — if this fails, no data loss occurs.
            // Images are deleted second; if image cleanup fails, we have a
            // storage leak (orphaned files) but the item is correctly removed.
            try await wardrobeRepository.deleteItem(id: item.id)
            items.removeAll { $0.id == item.id }

            // Best-effort image cleanup — don't fail the delete if this errors.
            // Masked path is nil on legacy (pre-00007) rows; the protocol
            // overload treats nil as "nothing to clean up here."
            do {
                try await imageService.deleteImages(
                    imagePath: item.imagePath,
                    thumbnailPath: item.thumbnailPath,
                    maskedImagePath: item.maskedImagePath
                )
            } catch {
                // Storage leak is acceptable; item is already deleted from DB
                errorMessage = "Item deleted, but image cleanup failed."
            }
        } catch {
            errorMessage = "Couldn't delete item."
        }
    }

    func thumbnailURL(for item: WardrobeItem) async -> URL? {
        // Prefer the cropped cutout (maskedImagePath) so two items extracted
        // from the same source photo render distinctly in the grid. Legacy
        // rows pre-migration 00007 fall back to the framed thumbnail.
        try? await imageService.signedURL(for: ItemCardView.displayPath(for: item))
    }

    func fullImageURL(for item: WardrobeItem) async -> URL? {
        try? await imageService.signedURL(for: item.imagePath)
    }

    /// Sign a session header's source photo path. Sessions share one
    /// `sourcePhotoPath` across N items, so callers cache the resulting
    /// URL by path rather than by item.
    func sourcePhotoURL(for path: String) async -> URL? {
        try? await imageService.signedURL(for: path)
    }
}
