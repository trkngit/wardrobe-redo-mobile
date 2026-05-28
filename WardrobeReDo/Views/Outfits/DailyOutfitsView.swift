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
            // Build 8: seed the occasion picker from on-device
            // memory. Decision was to keep occasion session-local
            // (not on `profiles`), but "session-local" felt wrong
            // when it reset to `.casual` every cold start. UserDefaults
            // splits the difference — feels like memory without
            // putting hourly-changing state in Postgres.
            viewModel.selectedOccasion = OccasionMemory.outfitsLastOccasion()
            await viewModel.loadOutfits(userId: user.id)
        }
        // Build 27 — `.refreshable` removed. It was attaching to
        // the horizontal occasion-chip ScrollView (the only
        // scrollable descendant of the body), so the user could
        // drag the chip row downward and trigger an unintended
        // refresh. The Build 26 `.scrollBounceBehavior` mitigation
        // wasn't sufficient. The Outfits tab already has two
        // explicit refresh paths (picker-change auto-regen +
        // Surprise me button), so pull-to-refresh was redundant
        // chrome anyway — removing it eliminates the gesture
        // conflict at the root rather than fighting it.
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
                    // Build 12 — long-press menu on the card.
                    // Quick path to react / mark worn without
                    // having to navigate into the detail view
                    // and back. Sets the same VM methods the
                    // detail view's reaction bar calls; the
                    // carousel re-renders the footer icon + the
                    // build-10 dim treatment for skip in the
                    // next animation tick.
                    .contextMenu {
                        outfitContextMenu(for: dailyOutfit)
                    }
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

    // MARK: - Build 12 — context menu

    /// Long-press menu on a card. Currently surfaces: love, like,
    /// skip, mark worn / un-worn. Each action mirrors the
    /// corresponding reaction-bar / wear-toggle on `OutfitDetailView`
    /// so behavior stays consistent — only the navigation cost
    /// changes. Toggling the same reaction clears it (matches the
    /// in-detail toggle semantic).
    @ViewBuilder
    private func outfitContextMenu(for dailyOutfit: DailyOutfit) -> some View {
        let outfitId = dailyOutfit.outfit.id
        let reaction = dailyOutfit.outfit.reaction

        Button {
            HapticManager.light()
            Task { await viewModel.react(outfitId: outfitId, reaction: "love") }
        } label: {
            Label(reaction == "love" ? "Unlove" : "Love", systemImage: "heart")
        }

        Button {
            HapticManager.light()
            Task { await viewModel.react(outfitId: outfitId, reaction: "like") }
        } label: {
            Label(reaction == "like" ? "Unlike" : "Like", systemImage: "hand.thumbsup")
        }

        Button {
            HapticManager.light()
            Task { await viewModel.react(outfitId: outfitId, reaction: "skip") }
        } label: {
            Label(reaction == "skip" ? "Un-skip" : "Skip", systemImage: "forward")
        }

        Divider()

        Button {
            HapticManager.medium()
            Task { await viewModel.toggleWorn(outfitId: outfitId) }
        } label: {
            Label(
                dailyOutfit.outfit.isWorn ? "Mark unworn" : "Mark worn",
                systemImage: dailyOutfit.outfit.isWorn ? "arrow.uturn.backward" : "checkmark.circle"
            )
        }
    }

    // MARK: - Vibe selector (build 6 + 7)

    private var vibePickerRow: some View {
        VibeSelector(vibe: Binding(
            get: { viewModel.selectedVibe },
            set: { newValue in
                // Build 8 — selection tick on every vibe stop.
                // Light, tactile feedback that confirms the tap
                // landed even before the regen completes. Skip
                // when the value didn't actually change so a
                // SwiftUI re-render doesn't double-buzz.
                if newValue != viewModel.selectedVibe {
                    HapticManager.selection()
                }
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
        // Build 28 — dice emoji removed. The 🎲 prefix read
        // "AI-sloppy" on a serious editorial CTA; the button now
        // says "Surprise me" / "Şaşırt beni" plain. Visual weight
        // comes from the new ink-primary palette and the press-
        // scale haptic, not from chrome.
        PrimaryButton(
            viewModel.isRegenerating ? "Rolling…" : "Surprise me",
            isLoading: viewModel.isRegenerating
        ) {
            guard !viewModel.isRegenerating else { return }
            guard let userId = appState.currentUser?.id else { return }
            // Build 8 — medium impact for a "deliberate action"
            // button (vs the selection tick on picker chips).
            // Communicates "something substantive just started"
            // without using `.success` which we reserve for the
            // post-completion confirmation in the toast.
            HapticManager.medium()
            viewModel.requestRegeneration(userId: userId, reason: .surpriseMe)
        }
        .disabled(viewModel.isRegenerating)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        // Build 8 — VoiceOver: the emoji-prefixed visible title
        // reads literally as "die emoji surprise me", which is
        // confusing. Override with a clean label and a hint
        // explaining what it actually does.
        .accessibilityLabel(viewModel.isRegenerating ? "Rolling" : "Surprise me")
        .accessibilityHint("Generates a different set of outfits with the same occasion and vibe")
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
            // Build 8 swaps in a direct "Add an Item" CTA that
            // deep-links to the Wardrobe tab's Add sheet so the
            // user doesn't have to manually switch tabs and find
            // the + button.
            if viewModel.lastFailure?.suggestsAddingItems == true {
                PrimaryButton("Add an Item") {
                    HapticManager.medium()
                    appState.pendingAddItem = true
                    appState.selectedTab = 0
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                .accessibilityHint("Opens the Wardrobe tab and presents the Add Item sheet")
            } else {
                PrimaryButton(
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
        // Build 26 / Bug C — `.scrollBounceBehavior(.basedOnSize)`
        // disables the rubber-band bounce when content is shorter
        // than the scroll area. Without it, iOS 17's
        // `ScrollView(.horizontal)` lets the user drag the row
        // VERTICALLY in a tiny window (the bounce direction is
        // perpendicular to the axis), which on this surface
        // bubbled up to the outer `.refreshable` and triggered an
        // unintended pull-to-refresh.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Occasion.allCases, id: \.self) { occasion in
                    Button {
                        // Build 7 — tapping an occasion now both
                        // updates state AND triggers a debounced
                        // regeneration. The VM cancels in-flight
                        // tasks so rapid tapping collapses cleanly
                        // into a single run.
                        // Build 8 — selection tick on a real
                        // state change (skip on re-tap-same).
                        if occasion != viewModel.selectedOccasion {
                            HapticManager.selection()
                        }
                        viewModel.selectedOccasion = occasion
                        // Build 8 — remember for the next launch.
                        // Cheap synchronous UserDefaults write;
                        // OK to do on the main thread.
                        OccasionMemory.setOutfitsLastOccasion(occasion)
                        if let userId = appState.currentUser?.id {
                            viewModel.requestRegeneration(userId: userId, reason: .pickerChange)
                        }
                    } label: {
                        // Build 14 — `Text(_ resource:)` pulls from
                        // the String Catalog so the chip reads
                        // "Casual" or "Günlük" depending on system
                        // language. Was `Text(occasion.displayName)`,
                        // which passed a plain String and bypassed
                        // localization entirely.
                        Text(occasion.localizedName)
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
                    // Build 8 — VoiceOver: announce the chip as a
                    // single button per row instead of "Casual,
                    // button" with no context. The `.isSelected`
                    // trait tells VoiceOver to read "selected"
                    // when it's the active occasion, which is the
                    // visual signal a sighted user gets from the
                    // gold capsule background.
                    // Build 27 — was `occasion.displayName` (raw
                    // English from the enum), which made Turkish
                    // VoiceOver users hear "Casual occasion" even
                    // under a Turkish locale. Routing through
                    // `String(localized: occasion.localizedName)`
                    // pulls the same catalog value the visible
                    // chip uses.
                    .accessibilityLabel("\(String(localized: occasion.localizedName))")
                    .accessibilityAddTraits(viewModel.selectedOccasion == occasion ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
        // Build 26 / Bug C — see comment above the ScrollView.
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Occasion picker")
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
