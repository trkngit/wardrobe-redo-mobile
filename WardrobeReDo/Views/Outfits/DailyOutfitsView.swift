import SwiftUI

/// The main Outfits tab: shows today's generated outfits in a paged
/// carousel. If none exist, presents a generation prompt with occasion
/// selector.
struct DailyOutfitsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = OutfitViewModel()
    @State private var selectedPage = 0

    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()

            if viewModel.isLoading {
                loadingState
            } else if viewModel.isGenerating {
                generatingState
            } else if viewModel.isEmpty {
                emptyState
            } else {
                outfitContent
            }
        }
        .navigationTitle("Today's Outfits")
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard let userId = appState.currentUser?.id else { return }
            await viewModel.loadOutfits(userId: userId)
        }
        .refreshable {
            guard let userId = appState.currentUser?.id else { return }
            await viewModel.loadOutfits(userId: userId)
        }
        .navigationDestination(for: UUID.self) { outfitId in
            if let dailyOutfit = viewModel.dailyOutfits.first(where: { $0.id == outfitId }) {
                OutfitDetailView(dailyOutfit: dailyOutfit, viewModel: viewModel)
            }
        }
    }

    // MARK: - Outfit Content

    private var outfitContent: some View {
        VStack(spacing: 0) {
            // Date header
            dateHeader

            // Paged carousel
            TabView(selection: $selectedPage) {
                ForEach(Array(viewModel.dailyOutfits.enumerated()), id: \.element.id) { index, dailyOutfit in
                    NavigationLink(value: dailyOutfit.id) {
                        OutfitCardView(
                            dailyOutfit: dailyOutfit,
                            thumbnailURLs: viewModel.thumbnailURLs
                        )
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.bottom, Theme.Spacing.xxl)
                    }
                    .buttonStyle(.plain)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            // Occasion selector
            occasionPicker
        }
    }

    // MARK: - Date Header

    private var dateHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayOfWeekString)
                    .font(Theme.Fonts.overline)
                    .foregroundStyle(Color(Theme.Colors.primary))
                    .textCase(.uppercase)

                Text(dateString)
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Spacer()

            Text("\(viewModel.dailyOutfits.count) outfits")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(Theme.Colors.primary))

            Text("Your Daily Outfits")
                .font(Theme.Fonts.h1)
                .foregroundStyle(Color(Theme.Colors.textPrimary))

            Text("Generate styled outfit suggestions\nfrom your wardrobe.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .multilineTextAlignment(.center)

            // Occasion selector
            occasionPicker
                .padding(.top, Theme.Spacing.sm)

            GoldButton("Generate Today's Outfits") {
                guard let userId = appState.currentUser?.id else { return }
                Task { await viewModel.generateDailyOutfits(userId: userId) }
            }
            .padding(.horizontal, Theme.Spacing.xxl)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.destructive))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Color(Theme.Colors.primary))
            Text("Loading outfits...")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
    }

    // MARK: - Generating State

    private var generatingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Color(Theme.Colors.primary))
                .scaleEffect(1.2)
            Text("Curating your outfits...")
                .font(Theme.Fonts.h3)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
            Text("Scoring combinations across 7 style dimensions")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
    }

    // MARK: - Occasion Picker

    private var occasionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Occasion.allCases, id: \.self) { occasion in
                    Button {
                        viewModel.selectedOccasion = occasion
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
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    // MARK: - Date Formatting

    private var dayOfWeekString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: Date())
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: Date())
    }
}

#Preview {
    NavigationStack {
        DailyOutfitsView()
    }
    .environment(AppState())
}
