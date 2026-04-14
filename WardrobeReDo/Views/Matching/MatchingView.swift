import SwiftUI
import Kingfisher

/// "What goes with this?" — select a hero item from your wardrobe
/// and see scored outfit suggestions built around it.
struct MatchingView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = MatchingViewModel()

    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()

            if viewModel.isLoading && viewModel.wardrobeItems.isEmpty {
                loadingState
            } else if viewModel.wardrobeItems.isEmpty {
                emptyWardrobeState
            } else {
                mainContent
            }
        }
        .navigationTitle("Match")
        .task {
            guard let userId = appState.currentUser?.id else { return }
            await viewModel.loadWardrobe(userId: userId)
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Hero item picker
                heroPickerSection

                // Occasion picker
                occasionPicker

                // Results
                if viewModel.isMatching {
                    matchingState
                } else if viewModel.hasResults {
                    resultsSection
                } else if viewModel.selectedItem != nil {
                    noResultsState
                } else {
                    promptState
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    // MARK: - Hero Item Picker

    private var heroPickerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Select a piece")
                .font(Theme.Fonts.h3)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .padding(.horizontal, Theme.Spacing.md)

            // Category filter
            categoryFilter

            // Item scroll
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.sm) {
                    ForEach(viewModel.filteredItems) { item in
                        heroItemCell(item)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
            .frame(height: 120)
        }
    }

    private func heroItemCell(_ item: WardrobeItem) -> some View {
        let isSelected = viewModel.selectedItem?.id == item.id

        return Button {
            guard let userId = appState.currentUser?.id else { return }
            Task { await viewModel.selectItem(item, userId: userId) }
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                KFImage(viewModel.thumbnailURLs[item.id])
                    .placeholder {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(Theme.Colors.muted).opacity(0.3))
                            .overlay {
                                Image(systemName: item.category.iconName)
                                    .font(.system(size: 16, weight: .light))
                                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                            }
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isSelected ? Color(Theme.Colors.primary) : Color.clear,
                                lineWidth: 2.5
                            )
                    )
                    .scaleEffect(isSelected ? 1.05 : 1.0)
                    .animation(Theme.Animation.spring, value: isSelected)

                Text(item.subcategory.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        isSelected
                            ? Color(Theme.Colors.primary)
                            : Color(Theme.Colors.textSecondary)
                    )
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                chipButton("All", isSelected: viewModel.selectedCategory == nil) {
                    viewModel.selectedCategory = nil
                }

                ForEach(ClothingCategory.allCases, id: \.self) { category in
                    chipButton(
                        category.displayName,
                        isSelected: viewModel.selectedCategory == category
                    ) {
                        viewModel.selectedCategory = viewModel.selectedCategory == category ? nil : category
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    private func chipButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(isSelected ? .white : Color(Theme.Colors.textPrimary))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 6)
                .background(isSelected ? Color(Theme.Colors.primary) : Color(Theme.Colors.surface))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color(Theme.Colors.border), lineWidth: 1)
                )
        }
        .animation(Theme.Animation.standard, value: isSelected)
    }

    // MARK: - Occasion Picker

    private var occasionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Occasion.allCases, id: \.self) { occasion in
                    Button {
                        guard let userId = appState.currentUser?.id else { return }
                        Task { await viewModel.changeOccasion(occasion, userId: userId) }
                    } label: {
                        Text(occasion.displayName)
                            .font(Theme.Fonts.bodySmall)
                            .foregroundStyle(
                                viewModel.selectedOccasion == occasion
                                    ? .white
                                    : Color(Theme.Colors.textPrimary)
                            )
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                viewModel.selectedOccasion == occasion
                                    ? Color(Theme.Colors.primary)
                                    : Color(Theme.Colors.muted).opacity(0.15)
                            )
                            .clipShape(Capsule())
                    }
                    .animation(Theme.Animation.standard, value: viewModel.selectedOccasion == occasion)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Outfit suggestions")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Spacer()

                Text("\(viewModel.matchResults.count) found")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
            .padding(.horizontal, Theme.Spacing.md)

            ForEach(Array(viewModel.matchResults.enumerated()), id: \.offset) { index, candidate in
                MatchResultCard(
                    candidate: candidate,
                    thumbnailURLs: viewModel.thumbnailURLs,
                    isSaved: viewModel.savedResultIndices.contains(index),
                    onSave: {
                        guard let userId = appState.currentUser?.id else { return }
                        Task { await viewModel.saveAsOutfit(at: index, userId: userId) }
                    }
                )
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Color(Theme.Colors.primary))
            Text("Loading wardrobe...")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
    }

    private var matchingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Color(Theme.Colors.primary))
            Text("Finding matches...")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
            Text("Scoring combinations across 7 style dimensions")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xxl)
    }

    private var promptState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color(Theme.Colors.primary).opacity(0.5))

            Text("Tap an item above to find\noutfits built around it")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xxl)
    }

    private var noResultsState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color(Theme.Colors.textSecondary).opacity(0.5))

            Text(viewModel.errorMessage ?? "No matching outfits found.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .multilineTextAlignment(.center)

            GhostButton("Try a different item") {
                viewModel.selectedItem = nil
                viewModel.matchResults = []
            }
            .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xxl)
    }

    private var emptyWardrobeState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Color(Theme.Colors.muted))

            Text("Add items to your wardrobe first")
                .font(Theme.Fonts.h2)
                .foregroundStyle(Color(Theme.Colors.textPrimary))

            Text("You'll need at least a few items\nbefore we can find matches.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
    }
}

#Preview {
    NavigationStack {
        MatchingView()
    }
    .environment(AppState())
}
