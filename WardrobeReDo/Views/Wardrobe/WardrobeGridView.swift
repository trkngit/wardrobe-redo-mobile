import SwiftUI
import Kingfisher

struct WardrobeGridView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = WardrobeViewModel()
    @State private var thumbnailURLs: [UUID: URL] = [:]
    /// Signed URLs keyed by `sourcePhotoPath` — sessions share the same
    /// source photo across N items, so we resolve once per path. Cleared
    /// alongside `thumbnailURLs` whenever the wardrobe reloads.
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
                        categoryFilters
                        itemCount
                        sessionList
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

    // MARK: - Item Count

    private var itemCount: some View {
        Text(viewModel.itemCountText)
            .font(Theme.Fonts.bodySmall)
            .foregroundStyle(Color(Theme.Colors.textSecondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Session List
    //
    // Sessions of >1 garment render with a header showing the source
    // photo + N-item count + relative date, followed by a 2-column grid
    // of cutouts beneath. Sessions of exactly 1 garment render as a
    // single full-width card with no header — we don't want the wardrobe
    // to look like "all sessions of 1 item." Section collapse is
    // deliberately deferred to a follow-up: keeping every session
    // expanded means less local state to manage and less risk of
    // regressions while the feature beds in.

    private var sessionList: some View {
        LazyVStack(spacing: Theme.Spacing.lg) {
            ForEach(Array(viewModel.sessions.enumerated()), id: \.element.id) { index, session in
                if session.items.count == 1 {
                    singleItemRow(session.items[0], staggerIndex: index)
                } else {
                    sessionBlock(session, staggerIndex: index)
                }
            }
        }
    }

    private func singleItemRow(_ item: WardrobeItem, staggerIndex: Int) -> some View {
        // Single-item captures keep the existing 2-column grid feel by
        // sitting in the same LazyVGrid as multi-item sessions would —
        // but as a "grid of one" so they take a half-width card and
        // align with the rest of the wardrobe visually.
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            NavigationLink(value: item.id) {
                ItemCardView(
                    item: item,
                    thumbnailURL: thumbnailURLs[item.id]
                )
                .staggeredFadeIn(index: staggerIndex)
            }
            .buttonStyle(.plain)
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

    private func loadThumbnails() async {
        for item in viewModel.items where thumbnailURLs[item.id] == nil {
            if let url = await viewModel.thumbnailURL(for: item) {
                thumbnailURLs[item.id] = url
            }
        }
        // Resolve session-header source-photo URLs once per unique path —
        // a 4-garment session shares the same sourcePhotoPath across all
        // items, so resolving per-path (not per-item) keeps API calls
        // proportional to captures.
        let uniqueSourcePaths = Set(
            viewModel.items.compactMap { $0.sourcePhotoPath }
        )
        for path in uniqueSourcePaths where sourcePhotoURLs[path] == nil {
            if let url = await viewModel.sourcePhotoURL(for: path) {
                sourcePhotoURLs[path] = url
            }
        }
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
