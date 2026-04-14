import SwiftUI

struct WardrobeGridView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = WardrobeViewModel()
    @State private var thumbnailURLs: [UUID: URL] = [:]

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
                        itemGrid
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

    // MARK: - Grid

    private var itemGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: item.id) {
                    ItemCardView(
                        item: item,
                        thumbnailURL: thumbnailURLs[item.id]
                    )
                    .staggeredFadeIn(index: index)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: UUID.self) { itemId in
            if let item = viewModel.items.first(where: { $0.id == itemId }) {
                ItemDetailView(item: item)
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
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Color(Theme.Colors.primary))
                .scaleEffect(1.2)
            Text("Loading wardrobe...")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
    }

    // MARK: - Helpers

    private func loadThumbnails() async {
        for item in viewModel.items where thumbnailURLs[item.id] == nil {
            if let url = await viewModel.thumbnailURL(for: item) {
                thumbnailURLs[item.id] = url
            }
        }
    }
}

#Preview {
    NavigationStack {
        WardrobeGridView()
    }
    .environment(AppState())
}
