import SwiftUI
import Kingfisher

struct WardrobeGridView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = WardrobeViewModel()
    /// Signed URLs for item thumbnails (the cropped cutout, falling back to
    /// the framed thumbnail). Pruned at the start of every `loadThumbnails`
    /// pass so entries for items the user just deleted don't linger for the
    /// lifetime of the view, and re-resolved every reload to dodge Supabase
    /// signed-URL TTL expiry (default 3600s).
    @State private var thumbnailURLs: [UUID: URL] = [:]
    /// Signed URLs keyed by `sourcePhotoPath` — sessions share the same
    /// source photo across N items, so we resolve once per path. Pruned the
    /// same way `thumbnailURLs` is on every `loadThumbnails` pass.
    @State private var sourcePhotoURLs: [String: URL] = [:]

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md),
    ]

    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                loadingState
            } else if viewModel.isEmpty && viewModel.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.md) {
                        // Build 9 — search bar above the category
                        // chips. Substring match across the visible
                        // strings on each card. Sits above the chips
                        // so the user can think "filter by category
                        // OR type a name" — both narrow the same list.
                        searchBar
                        categoryFilters
                        itemCount
                        if viewModel.filteredItems.isEmpty {
                            searchEmptyState
                        } else {
                            sessionList
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.sm)
                    .padding(.bottom, Theme.Spacing.xxl)
                }
                .refreshable {
                    guard let userId = appState.currentUser?.id else { return }
                    await viewModel.loadItems(userId: userId)
                    await loadThumbnails()
                }
            }
        }
        .navigationTitle("Wardrobe")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showAddItem = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(Theme.Colors.primary))
                }
            }
        }
        .sheet(isPresented: $viewModel.showAddItem) {
            AddItemView()
                .environment(appState)
        }
        .onChange(of: viewModel.showAddItem) {
            if !viewModel.showAddItem {
                Task {
                    guard let userId = appState.currentUser?.id else { return }
                    await viewModel.loadItems(userId: userId)
                    await loadThumbnails()
                }
            }
        }
        .task {
            guard let userId = appState.currentUser?.id else { return }
            await viewModel.loadItems(userId: userId)
            await loadThumbnails()
        }
        // Build 8 — honor cross-tab deep-link from the Outfits /
        // Match failure CTAs. Clear the flag immediately so a
        // later tab switch doesn't re-present the sheet
        // unexpectedly. Runs in `onAppear` (vs `task`) because
        // tab switches don't recreate the view's task.
        .onAppear {
            if appState.pendingAddItem {
                appState.pendingAddItem = false
                viewModel.showAddItem = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wardrobeDidChange)) { _ in
            guard let userId = appState.currentUser?.id else { return }
            Task {
                await viewModel.loadItems(userId: userId)
                await loadThumbnails()
            }
        }
        .navigationDestination(for: UUID.self) { itemId in
            if let item = viewModel.items.first(where: { $0.id == itemId }) {
                ItemDetailView(item: item)
            }
        }
    }

    // MARK: - Search Bar (build 9)

    /// Build 9 — free-text wardrobe filter. Matches on subcategory
    /// name ("Sneakers"), category name ("Shoe"), and texture
    /// ("Denim"). Uses a `@Bindable` shortcut on the VM so the
    /// TextField writes directly to `searchQuery`, which already
    /// triggers `recomputeSessions()` via its `didSet`.
    private var searchBar: some View {
        @Bindable var vm = viewModel
        return HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            TextField("Search wardrobe", text: $vm.searchQuery)
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !viewModel.searchQuery.isEmpty {
                Button {
                    HapticManager.light()
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .stroke(Color(Theme.Colors.border), lineWidth: 1)
        )
    }

    /// Empty state shown when a search / category combination
    /// returns zero items. Stays in-flow with the search bar
    /// above so the user can keep typing or clear the query
    /// without losing context.
    private var searchEmptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(Color(Theme.Colors.muted))
                .padding(.top, Theme.Spacing.xl)

            Text("No items match your search")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            if !viewModel.searchQuery.isEmpty {
                Button("Clear search") {
                    HapticManager.light()
                    viewModel.searchQuery = ""
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.primary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.lg)
    }

    // MARK: - Category Filters

    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                filterChip("All", isSelected: viewModel.selectedCategory == nil) {
                    viewModel.selectCategory(nil)
                }

                ForEach(ClothingCategory.allCases, id: \.self) { category in
                    filterChip(
                        category.displayName,
                        icon: category.iconName,
                        isSelected: viewModel.selectedCategory == category
                    ) {
                        viewModel.selectCategory(category)
                    }
                }
            }
        }
    }

    private func filterChip(
        _ title: String,
        icon: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(Theme.Fonts.caption)
            }
            .foregroundStyle(isSelected ? .white : Color(Theme.Colors.textPrimary))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(isSelected ? Color(Theme.Colors.primary) : Color(Theme.Colors.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .stroke(isSelected ? Color.clear : Color(Theme.Colors.border), lineWidth: 1)
            )
            .scaleEffect(isSelected ? 1.05 : 1.0)
        }
        .animation(Theme.Animation.spring, value: isSelected)
    }

    // MARK: - Item Count + sort menu (build 11)

    /// Row showing the filtered item count on the left and a sort
    /// menu on the right. Pre-Build-11 this was just text; the
    /// menu lives here because it lines up visually with the count
    /// the user is staring at — "X items, sorted by Y" reads as one
    /// thought.
    private var itemCount: some View {
        HStack {
            Text(viewModel.itemCountText)
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            Spacer()

            sortMenu
        }
    }

    /// Build 11 — SwiftUI `Menu` picker for sort order. Uses the
    /// system menu look (button + caret) and the enum's icon names
    /// so each option carries a glyph that hints at the semantic
    /// (clock = newest, flame = most worn, sparkles = least worn).
    /// Selection mutates the VM and the `didSet` recomputes the
    /// session list, which the grid re-renders.
    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Button {
                    HapticManager.selection()
                    viewModel.sortOrder = order
                } label: {
                    Label(order.displayName, systemImage: order.iconName)
                    if viewModel.sortOrder == order {
                        // SwiftUI menu items render a trailing
                        // checkmark when the body contains both
                        // a Label and a system-style indicator
                        // implicit on iOS — keeping this Image
                        // explicit makes the selection state
                        // unmissable on older OS versions too.
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.sortOrder.iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(viewModel.sortOrder.displayName)
                    .font(Theme.Fonts.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color(Theme.Colors.primary))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 4)
            .background(Color(Theme.Colors.primaryMuted).opacity(0.6))
            .clipShape(Capsule())
        }
        .accessibilityLabel("Sort by")
        .accessibilityValue(viewModel.sortOrder.displayName)
        .accessibilityHint("Change how wardrobe items are ordered")
    }

    // MARK: - Session List
    //
    // Sessions of >1 garment render with a header showing the source
    // photo + N-item count + relative date, followed by a 2-column grid
    // of cutouts beneath. Consecutive single-item sessions fuse into one
    // shared 2-column grid (via `viewModel.groupedSessions`) so two
    // singles in a row pack side-by-side instead of each becoming a
    // half-width card with empty space on the right. Section collapse is
    // deliberately deferred to a follow-up: keeping every session
    // expanded means less local state to manage and less risk of
    // regressions while the feature beds in.

    private var sessionList: some View {
        LazyVStack(spacing: Theme.Spacing.lg) {
            ForEach(viewModel.groupedSessions) { group in
                switch group {
                case .singles(let items, let staggerStart):
                    singlesGrid(items: items, staggerStart: staggerStart)
                case .session(let session, let staggerStart):
                    sessionBlock(session, staggerIndex: staggerStart)
                }
            }
        }
    }

    private func singlesGrid(items: [WardrobeItem], staggerStart: Int) -> some View {
        // Run of consecutive single-item sessions packed into one
        // shared 2-column grid. Stagger indices continue from the
        // run's `staggerStart` so the fade-in timing across multi-
        // and single-item blocks stays in lockstep with visual order.
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                NavigationLink(value: item.id) {
                    ItemCardView(
                        item: item,
                        thumbnailURL: thumbnailURLs[item.id]
                    )
                    .staggeredFadeIn(index: staggerStart + offset)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sessionBlock(_ session: WardrobeSession, staggerIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sessionHeader(session)
            sessionGrid(session, staggerIndex: staggerIndex)
        }
    }

    private func sessionHeader(_ session: WardrobeSession) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            sessionThumbnail(session)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionItemCountText(for: session))
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                Text(relativeDateText(for: session.createdAt))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Spacer()
        }
        .padding(.vertical, Theme.Spacing.xs)
        // Without this, VoiceOver reads each label as its own element
        // (the photo, the count, the date) with no semantic grouping. The
        // combine modifier joins them under one accessibility node and the
        // explicit label reads naturally instead of "44 by 44 image, 3
        // items, 2h ago" pieced together by the screen reader.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Capture session, \(sessionItemCountText(for: session)), " +
            relativeDateText(for: session.createdAt)
        )
    }

    private func sessionThumbnail(_ session: WardrobeSession) -> some View {
        let url: URL? = session.sourcePhotoPath.flatMap { sourcePhotoURLs[$0] }
        return KFImage(url)
            .placeholder {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Color(Theme.Colors.muted).opacity(0.3))
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
            }
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func sessionGrid(_ session: WardrobeSession, staggerIndex: Int) -> some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            ForEach(Array(session.items.enumerated()), id: \.element.id) { itemIndex, item in
                NavigationLink(value: item.id) {
                    ItemCardView(
                        item: item,
                        thumbnailURL: thumbnailURLs[item.id]
                    )
                    .staggeredFadeIn(index: staggerIndex + itemIndex)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "tshirt")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Color(Theme.Colors.muted))

            VStack(spacing: Theme.Spacing.sm) {
                Text("Your wardrobe is empty")
                    .font(Theme.Fonts.h2)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                Text("Add your first item to get started with personalized outfit suggestions.")
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
            }

            GoldButton("Add First Item") {
                viewModel.showAddItem = true
            }
            .frame(maxWidth: 200)
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                // Fake filter chips shimmer
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(Color(Theme.Colors.muted).opacity(0.15))
                            .frame(width: 70, height: 32)
                            .shimmer()
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.md)

                WardrobeGridShimmer(count: 6)
            }
            .padding(.top, Theme.Spacing.sm)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func loadThumbnails() async {
        // Drop entries whose underlying item / source path is no longer in
        // the live wardrobe before resolving anything new. Without this,
        // signed URLs for deleted items linger for the lifetime of the
        // view and stale session-header URLs persist after a re-upload
        // changes a row's `sourcePhotoPath`.
        thumbnailURLs = Self.pruneItemCache(
            thumbnailURLs,
            against: viewModel.items
        )
        sourcePhotoURLs = Self.pruneSourcePathCache(
            sourcePhotoURLs,
            against: viewModel.items
        )

        // Snapshot the work list outside the task group so the closure
        // captures only Sendable values (UUIDs, items, paths) — never the
        // view or the view model. Sequential awaits multiplied RTT by N
        // items; the TaskGroup fans out so total latency tracks the slowest
        // single signed-URL call rather than the sum.
        let itemsToResolve = viewModel.items.filter { thumbnailURLs[$0.id] == nil }
        let pathsToResolve = Set(
            viewModel.items.compactMap(\.sourcePhotoPath)
        ).subtracting(sourcePhotoURLs.keys)

        let resolvedItems = await Self.resolveItemURLs(
            items: itemsToResolve,
            using: viewModel
        )
        for (id, url) in resolvedItems {
            thumbnailURLs[id] = url
        }

        let resolvedPaths = await Self.resolveSourcePathURLs(
            paths: pathsToResolve,
            using: viewModel
        )
        for (path, url) in resolvedPaths {
            sourcePhotoURLs[path] = url
        }
    }

    /// Fan-out signing for item thumbnails. Pulled into a static helper so
    /// the TaskGroup closure captures only Sendable values (the items and
    /// the actor-isolated view model reference) — no `self`, no `@State`.
    /// Returns successful resolutions only; a nil URL means the signed-URL
    /// call failed for that item and the caller should leave the cache
    /// entry unset.
    private static func resolveItemURLs(
        items: [WardrobeItem],
        using viewModel: WardrobeViewModel
    ) async -> [(UUID, URL)] {
        await withTaskGroup(of: (UUID, URL?).self) { group in
            for item in items {
                group.addTask {
                    let url = await viewModel.thumbnailURL(for: item)
                    return (item.id, url)
                }
            }
            var resolved: [(UUID, URL)] = []
            for await (id, url) in group {
                if let url { resolved.append((id, url)) }
            }
            return resolved
        }
    }

    /// Fan-out signing for session-header source photos. One signed-URL per
    /// unique path keeps API calls proportional to captures, not items —
    /// a 4-garment session shares the same sourcePhotoPath across all
    /// items.
    private static func resolveSourcePathURLs(
        paths: Set<String>,
        using viewModel: WardrobeViewModel
    ) async -> [(String, URL)] {
        await withTaskGroup(of: (String, URL?).self) { group in
            for path in paths {
                group.addTask {
                    let url = await viewModel.sourcePhotoURL(for: path)
                    return (path, url)
                }
            }
            var resolved: [(String, URL)] = []
            for await (path, url) in group {
                if let url { resolved.append((path, url)) }
            }
            return resolved
        }
    }

    /// Drops `cache` entries whose key isn't in the live items list. Pure
    /// data transform pulled out of `loadThumbnails` so the contract can
    /// be exercised in tests without standing up `@State` or a real view.
    /// Internal so the unit-test target can call it.
    static func pruneItemCache(
        _ cache: [UUID: URL],
        against items: [WardrobeItem]
    ) -> [UUID: URL] {
        let liveIds = Set(items.map(\.id))
        return cache.filter { liveIds.contains($0.key) }
    }

    /// Drops session-header URL entries whose source path isn't referenced
    /// by any live item. Mirrors `pruneItemCache` for the by-path cache.
    static func pruneSourcePathCache(
        _ cache: [String: URL],
        against items: [WardrobeItem]
    ) -> [String: URL] {
        let livePaths = Set(items.compactMap(\.sourcePhotoPath))
        return cache.filter { livePaths.contains($0.key) }
    }

    private func sessionItemCountText(for session: WardrobeSession) -> String {
        let n = session.items.count
        return n == 1 ? "1 item" : "\(n) items"
    }

    /// Lightweight relative-time formatter mirroring iOS Mail's "5m ago,
    /// 2h ago, Yesterday, 3d ago" style. Falls back to a short date for
    /// captures older than a week so the header stays compact on phones.
    private func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    NavigationStack {
        WardrobeGridView()
    }
    .environment(AppState())
}
