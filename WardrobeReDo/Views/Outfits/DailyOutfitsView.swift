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
            guard let user = appState.currentUser else { return }
            // Build 6: seed the slider from the user's stored
            // default vibe so future generations start where they
            // asked. The per-generation chip override stays local
            // to the VM — flipping it here won't persist back to
            // Supabase unless the user explicitly taps "Make this my
            // default" in Settings.
            viewModel.selectedVibe = user.defaultVibe
            await viewModel.loadOutfits(userId: user.id)
        }
        .refreshable {
            guard let userId = appState.currentUser?.id else { return }
            await viewModel.loadOutfits(userId: userId)
        }
        .navigationDestination(for: UUID.self) { outfitId in
            OutfitDetailView(outfitId: outfitId, viewModel: viewModel)
        }
        // Build 7 — brief "Updated for [occasion] · [vibe]" toast
        // when a picker change triggers a debounced regeneration.
        // The modifier auto-clears the message after 1.5 s; the
        // VM sets it inside `requestRegeneration(reason: .pickerChange)`.
        .statusToast(message: Binding(
            get: { viewModel.statusToastMessage },
            set: { viewModel.statusToastMessage = $0 }
        ))
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
            // Build 7 — crossfade between outfit sets on regen.
            // The `id:` on the keypath makes SwiftUI replace the
            // TabView's identity when the daily-outfit list shifts,
            // which triggers the transition. Without this the cards
            // change in place with no motion cue and the "idle"
            // feeling persists.
            .animation(Theme.Animation.standard, value: viewModel.dailyOutfits.map(\.id))
            .onChange(of: viewModel.dailyOutfits.count) { _, newCount in
                // Preserve the user's carousel position when it's
                // still in bounds — avoid jarring jumps to page 0
                // when results re-rank.
                if selectedPage >= newCount {
                    selectedPage = max(0, newCount - 1)
                }
            }

            // Occasion selector
            occasionPicker

            // Build 6 — vibe selector. Slots between the occasion
            // picker and the regenerate button so the user can tune
            // "what kind of outfit" (occasion) AND "how adventurous"
            // (vibe) before hitting Generate.
            vibePickerRow

            // Regenerate button — re-rolls today's outfits with a fresh
            // seed so the user gets a different combination on demand.
            // Lives below the picker so it's adjacent to the occasion
            // they may have just changed.
            regenerateButton
        }
    }

    // MARK: - Vibe selector (build 6 + 7)

    private var vibePickerRow: some View {
        VibeSelector(vibe: Binding(
            get: { viewModel.selectedVibe },
            set: { newValue in
                viewModel.selectedVibe = newValue
                // Build 6 — log overrides so we can see how often
                // users pick something other than their saved
                // default. Sampled at chip-tap rather than on every
                // generate because most generates inherit the
                // existing slider state.
                if let defaultVibe = appState.currentUser?.defaultVibe {
                    VibeTelemetry.logOverride(default: defaultVibe, selected: newValue, source: "outfits")
                }
                // Build 7 — live regeneration. The VM debounces
                // 250 ms and cancels older tasks so rapid drags
                // collapse into a single beam search.
                if let userId = appState.currentUser?.id {
                    viewModel.requestRegeneration(userId: userId, reason: .pickerChange)
                }
            }
        ))
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: - "Surprise me" re-roll button (build 7)

    /// Build 7 — renamed from "Generate New Outfits". Build 6 made
    /// this the only path to regeneration; build 7 makes picker
    /// changes auto-regenerate, leaving this button as the
    /// explicit "give me variety" affordance — runs the engine
    /// with the same occasion + vibe but a fresh random seed.
    private var regenerateButton: some View {
        GoldButton(
            viewModel.isRegenerating ? "Rolling…" : "🎲 Surprise me",
            isLoading: viewModel.isRegenerating
        ) {
            guard !viewModel.isRegenerating else { return }
            guard let userId = appState.currentUser?.id else { return }
            viewModel.requestRegeneration(userId: userId, reason: .surpriseMe)
        }
        .disabled(viewModel.isRegenerating)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
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

            // Reason-specific failure message takes precedence over the
            // generic "Generate styled outfit suggestions" prompt — it
            // tells the user exactly what went wrong.
            if let failure = viewModel.lastFailure {
                failureBanner(failure)
            } else {
                Text("Generate styled outfit suggestions\nfrom your wardrobe.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
            }

            // Occasion selector
            occasionPicker
                .padding(.top, Theme.Spacing.sm)

            // Hide the Generate / Try-Again CTA when the failure
            // explicitly suggests adding items first — tapping it
            // would just re-hit the same wardrobe-too-small failure.
            // The failureBanner copy already nudges toward the
            // Wardrobe tab, which is the action that helps.
            if viewModel.lastFailure?.suggestsAddingItems != true {
                GoldButton(
                    viewModel.lastFailure == nil ? "Generate Today's Outfits" : "Try Again",
                    isLoading: viewModel.isGenerating
                ) {
                    guard !viewModel.isGenerating else { return }
                    guard let userId = appState.currentUser?.id else { return }
                    Task { await viewModel.generateDailyOutfits(userId: userId) }
                }
                .disabled(viewModel.isGenerating)
                .padding(.horizontal, Theme.Spacing.xxl)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    /// Reason-specific empty-state copy. The wardrobe-too-small case
    /// also nudges the user toward the Wardrobe tab.
    private func failureBanner(_ failure: GenerationFailure) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(failure.userMessage)
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .multilineTextAlignment(.center)

            if failure.suggestsAddingItems {
                Text("Open the Wardrobe tab to add a piece.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary).opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                OutfitCardShimmer()
                    .padding(.horizontal, Theme.Spacing.lg)
                OutfitCardShimmer()
                    .padding(.horizontal, Theme.Spacing.lg)
            }
            .padding(.top, Theme.Spacing.md)
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
                        // Build 7 — tapping an occasion now both
                        // updates state AND triggers a debounced
                        // regeneration. The VM cancels in-flight
                        // tasks so rapid tapping collapses cleanly
                        // into a single run.
                        viewModel.selectedOccasion = occasion
                        if let userId = appState.currentUser?.id {
                            viewModel.requestRegeneration(userId: userId, reason: .pickerChange)
                        }
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
