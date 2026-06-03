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
            guard let user = appState.currentUser else { return }
            // Build 6: seed the matching slider from the user's
            // stored default vibe so the Match flow starts at the
            // same intensity as the Outfits flow does.
            viewModel.selectedVibe = user.defaultVibe
            // Build 8: seed occasion from on-device memory.
            // Per-surface so a user matching a blazer at "work"
            // doesn't get blown away by their Outfits-tab "date" pick.
            viewModel.selectedOccasion = OccasionMemory.matchLastOccasion()
            await viewModel.loadWardrobe(userId: user.id)
        }
        // Build 9 — pull-to-refresh parity with the Outfits tab.
        // Refreshes the wardrobe items underneath the picker so a
        // user who just added a piece in another tab can pull-down
        // and see it without backing out of Match. If a hero is
        // already selected, the match results re-rank on the new
        // wardrobe snapshot.
        .refreshable {
            guard let userId = appState.currentUser?.id else { return }
            // Build 25 — confirmation haptic on pull-to-refresh.
            HapticManager.medium()
            await viewModel.loadWardrobe(userId: userId)
            if viewModel.selectedItem != nil {
                await viewModel.findMatches(userId: userId)
            }
        }
        // Build 7 — "Updated for [occasion] · [vibe]" toast,
        // identical pattern to the Outfits tab.
        .statusToast(message: Binding(
            get: { viewModel.statusToastMessage },
            set: { viewModel.statusToastMessage = $0 }
        ))
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Hero item picker
                heroPickerSection

                // Occasion picker
                occasionPicker

                // Build 6 — vibe slider between occasion and
                // results. Adjusting the slider re-runs match
                // generation through `onChange` so the user sees
                // the new ranking immediately.
                vibePickerRow

                // Build 8 — parity with the Outfits tab. The
                // match engine doesn't take a seed, but re-running
                // with the same hero/occasion/vibe still shuffles
                // results via the cached recent-pair signal — so
                // "Surprise me" gives the user a fresh ranking
                // without forcing them to change their picks.
                // Gated to "hero selected" because matching is
                // hero-anchored (the VM no-ops otherwise).
                if viewModel.selectedItem != nil {
                    surpriseMeButton
                }

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

                // Build 17 — localized subcategory name.
                Text(item.subcategory.localizedName)
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
        // Build 8 — VoiceOver: the visible cell is a tiny thumbnail
        // + one-word subcategory. Without these, VoiceOver reads
        // "T-Shirt, button" with no indication it's a wardrobe item
        // or that it's the selected hero. The label here adds
        // category context; the hint explains the tap action.
        .accessibilityLabel("\(item.subcategory.displayName) \(item.category.displayName.lowercased())")
        .accessibilityHint(isSelected
            ? "Selected as the piece to match. Tap to deselect."
            : "Tap to find outfits built around this piece.")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        // Build 51 — wrapping FlowLayout of shared Chips (was an
        // equal-width LazyVGrid that left ragged gaps between columns;
        // see WardrobeGridView for the same fix).
        FlowLayout(spacing: Theme.Spacing.sm) {
            Chip(LocalizedStringResource("All"), isSelected: viewModel.selectedCategory == nil) {
                viewModel.selectedCategory = nil
            }
            ForEach(ClothingCategory.allCases, id: \.self) { category in
                Chip(
                    category.localizedName,
                    isSelected: viewModel.selectedCategory == category
                ) {
                    viewModel.selectedCategory = viewModel.selectedCategory == category ? nil : category
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - Vibe Picker (build 6 + 7)

    private var vibePickerRow: some View {
        VibeSelector(
            vibe: Binding(
                get: { viewModel.selectedVibe },
                set: { newVibe in
                    // Build 8 — selection tick on real change only.
                    if newVibe != viewModel.selectedVibe {
                        HapticManager.selection()
                    }
                    viewModel.selectedVibe = newVibe
                    if let defaultVibe = appState.currentUser?.defaultVibe {
                        VibeTelemetry.logOverride(default: defaultVibe, selected: newVibe, source: "match")
                    }
                    // Build 7 — same funnel as Outfits tab. The VM
                    // debounces + cancels in-flight tasks so a
                    // dragged slider doesn't queue 5 matches.
                    if let userId = appState.currentUser?.id {
                        viewModel.requestRegeneration(userId: userId, reason: .pickerChange)
                    }
                }
            )
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - "Surprise me" re-roll (build 8)

    /// Build 8 — parity with `DailyOutfitsView.regenerateButton`.
    /// Re-runs the matcher with the same hero + occasion + vibe;
    /// the recent-pair history changes the ranking naturally
    /// between runs even though the match engine doesn't accept
    /// an explicit seed. Loading title mirrors the Outfits tab
    /// ("Rolling…") for cross-surface consistency.
    private var surpriseMeButton: some View {
        // Build 28 — dice emoji dropped; see DailyOutfitsView for
        // the same rationale.
        PrimaryButton(
            viewModel.isMatching ? "Rolling…" : "Surprise me",
            isLoading: viewModel.isMatching
        ) {
            guard !viewModel.isMatching else { return }
            guard let userId = appState.currentUser?.id else { return }
            // Build 8 — deliberate-action haptic. See the matching
            // call in `DailyOutfitsView.regenerateButton`.
            HapticManager.medium()
            viewModel.requestRegeneration(userId: userId, reason: .surpriseMe)
        }
        .disabled(viewModel.isMatching)
        .padding(.horizontal, Theme.Spacing.md)
        // Build 8 — accessibility parity with Outfits tab.
        .accessibilityLabel(viewModel.isMatching ? "Rolling" : "Surprise me")
        .accessibilityHint("Re-ranks the match results with the same hero piece, occasion, and vibe")
    }

    // MARK: - Occasion Picker

    private var occasionPicker: some View {
        // Build 51 — wrapping FlowLayout of shared Chips (was an
        // equal-width LazyVGrid). Every occasion shows at once and the
        // flow layout can't intercept the pull-to-refresh gesture, so the
        // Build-26 `.scrollBounceBehavior` workaround stays unneeded.
        FlowLayout(spacing: Theme.Spacing.sm) {
            ForEach(Occasion.allCases, id: \.self) { occasion in
                Chip(occasion.localizedName, isSelected: viewModel.selectedOccasion == occasion) {
                    // Build 7 — an occasion tap mutates state and routes
                    // through the same `requestRegeneration` funnel as the
                    // vibe slider (the no-op guard lives in the VM).
                    // Build 8 — selection tick on a real change only.
                    if occasion != viewModel.selectedOccasion {
                        HapticManager.selection()
                    }
                    viewModel.selectedOccasion = occasion
                    // Build 8 — per-tab on-device memory of the last pick.
                    OccasionMemory.setMatchLastOccasion(occasion)
                    if let userId = appState.currentUser?.id {
                        viewModel.requestRegeneration(userId: userId, reason: .pickerChange)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Occasion picker")
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

            // Build 10 — bulk-save affordance. Shown only when at
            // least one result is still unsaved (and at least 2
            // total — for a single match the per-card Save button
            // is plenty). Count in the label is honest about what
            // tapping it does — "Save all (3)" is clearer than a
            // bare "Save all" when some are already in.
            if viewModel.matchResults.count > 1, viewModel.unsavedResultCount > 0 {
                saveAllButton
                    .padding(.horizontal, Theme.Spacing.md)
            }

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
                .transition(.opacity)
            }
        }
        // Build 7 — crossfade the result list when the ranking
        // shifts under a debounced regen. `matchResults` is the
        // animation key; whenever the array contents shift,
        // SwiftUI re-applies the transition above on each card.
        .animation(Theme.Animation.standard, value: viewModel.matchResults.count)
    }

    // MARK: - Save-all (build 10)

    /// Build 10 — secondary CTA below the result-count header that
    /// persists every unsaved candidate in one round-trip. Uses
    /// `GhostButton` (outlined, not filled) so it doesn't compete
    /// visually with each card's own primary Save button — this is
    /// a "shortcut to the same five taps" affordance, not a new
    /// destination. Success haptic on completion since the result
    /// is a state shift you'd otherwise infer from the cards
    /// quietly all marking themselves Saved.
    private var saveAllButton: some View {
        GhostButton("Save all (\(viewModel.unsavedResultCount))") {
            guard let userId = appState.currentUser?.id else { return }
            HapticManager.medium()
            Task {
                await viewModel.saveAllResults(userId: userId)
                HapticManager.success()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHint("Saves every match result not already saved")
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

            // Prefer the reason-specific message from `lastFailure`, but
            // fall back to `errorMessage` for any code path that hasn't
            // adopted the new enum yet.
            Text(viewModel.lastFailure?.userMessage
                 ?? viewModel.errorMessage
                 ?? "No matching outfits found.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.lg)

            // Try Again — re-runs matching with the same hero & occasion.
            // Only shown when there's a recoverable failure (i.e. a hero
            // is still selected).
            if viewModel.selectedItem != nil && viewModel.lastFailure != nil {
                PrimaryButton("Try Again", isLoading: viewModel.isMatching) {
                    guard let userId = appState.currentUser?.id else { return }
                    Task { await viewModel.findMatches(userId: userId) }
                }
                .frame(maxWidth: 240)
                .padding(.horizontal, Theme.Spacing.lg)
            }

            GhostButton("Try a different item") {
                viewModel.selectedItem = nil
                viewModel.matchResults = []
                viewModel.lastFailure = nil
                viewModel.errorMessage = nil
            }
            .frame(maxWidth: 240)
            .padding(.horizontal, Theme.Spacing.lg)
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

            // Build 8 — direct deep-link to the Wardrobe Add sheet.
            // Saves the user from hunting for the + button in the
            // wardrobe toolbar after switching tabs.
            PrimaryButton("Add an Item") {
                HapticManager.medium()
                appState.pendingAddItem = true
                appState.selectedTab = 0
            }
            .frame(maxWidth: 240)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.sm)
            .accessibilityHint("Opens the Wardrobe tab and presents the Add Item sheet")
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
