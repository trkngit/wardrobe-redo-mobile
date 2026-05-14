import SwiftUI

/// Profile tab: user info, wardrobe stats, style preference editor,
/// notification toggle, and sign out.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var stats = ProfileStats()
    @State private var notificationsEnabled = NotificationService.shared.isEnabled
    @State private var showPreferencesEditor = false
    @State private var isLoadingStats = false
    @State private var cacheSize: String = "—"
    @State private var isClearingCache = false
    // Build 15 — language picker state. Seeded from
    // `LanguageManager.current` so the row reflects whatever
    // override is already in effect on this device.
    @State private var selectedLanguage: AppLanguage = LanguageManager.current
    @State private var showLanguageRestartHint = false

    private let wardrobeRepository = WardrobeRepository()
    private let outfitRepository = OutfitRepository()

    var body: some View {
        List {
            userInfoSection
            statsSection
            defaultVibeSection
            preferencesSection
            notificationsSection
            // Build 15 — language picker between Notifications
            // and Image Cache. Lives near the bottom of the list
            // because it's an infrequent change, but above About
            // so users actually see it without scrolling all the
            // way down.
            languageSection
            cacheSection
            aboutSection
            #if DEBUG
            developerSection
            #endif
            signOutSection
        }
        .navigationTitle("Profile")
        .task {
            await loadStats()
            cacheSize = await ImageCacheService.formattedDiskCacheSize()
        }
        .sheet(isPresented: $showPreferencesEditor) {
            NavigationStack {
                StylePreferencesEditor()
                    .environment(appState)
            }
        }
    }

    // MARK: - User Info

    private var userInfoSection: some View {
        Section {
            if let user = appState.currentUser {
                HStack(spacing: Theme.Spacing.md) {
                    Circle()
                        .fill(Color(Theme.Colors.primaryMuted))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Text(user.displayName.prefix(1).uppercased())
                                .font(Theme.Fonts.h2)
                                .foregroundStyle(Color(Theme.Colors.primary))
                        )

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(user.displayName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color(Theme.Colors.textPrimary))

                        Text(user.tier.capitalized)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Color(Theme.Colors.primary))
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 2)
                            .background(Color(Theme.Colors.primaryMuted))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Section("Wardrobe Stats") {
            statRow(label: "Total Items", value: "\(stats.totalItems)", icon: "tshirt")
            statRow(label: "Outfits Generated", value: "\(stats.outfitsGenerated)", icon: "sparkles")
            statRow(label: "Items Worn", value: "\(stats.itemsWorn)", icon: "checkmark.circle")

            if let mostWorn = stats.mostWornCategory {
                // Build 27 — resolve the localized category name
                // at render time. See `ProfileStats` for why we
                // stopped storing the displayName.
                statRow(
                    label: "Most Worn",
                    value: String(localized: mostWorn.localizedName),
                    icon: "flame"
                )
            }
        }
    }

    // Build 27 — was `label: String`, which routed through
    // `Text(verbatim:)` and bypassed the catalog even though every
    // label (Total Items / Outfits Generated / Items Worn / Most
    // Worn) HAS a Turkish translation in `Localizable.xcstrings`.
    // `LocalizedStringResource` is the correct carrier; existing
    // call sites pass string literals which auto-coerce.
    // `value` stays `String` because it's interpolated user data
    // ("12", "39") — not a localized string.
    private func statRow(label: LocalizedStringResource, value: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color(Theme.Colors.primary))
                .frame(width: 20)

            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textPrimary))

            Spacer()

            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
    }

    // MARK: - Default Vibe (build 6)

    private var defaultVibeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Default vibe")
                    .font(Theme.Fonts.body)
                Text("Where every outfit-generation session starts. You can still slide between Safe and Bold on the Outfits screen.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                VibeSelector(vibe: Binding(
                    get: { appState.currentUser?.defaultVibe ?? .balanced },
                    set: { newValue in
                        Task { await saveDefaultVibe(newValue) }
                    }
                ))
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func saveDefaultVibe(_ vibe: VibeStop) async {
        guard let userId = appState.currentUser?.id else { return }
        // Optimistic UI: write through to the in-memory profile so
        // the slider doesn't snap back while the network call is
        // in flight. Roll back if the persistence fails.
        let previous = appState.currentUser?.defaultVibe ?? .balanced
        if var profile = appState.currentUser {
            profile.defaultVibe = vibe
            appState.currentUser = profile
        }
        do {
            try await UserRepository().updateDefaultVibe(userId: userId, vibe: vibe)
            VibeTelemetry.logDefaultChanged(to: vibe, via: "settings")
        } catch {
            if var profile = appState.currentUser {
                profile.defaultVibe = previous
                appState.currentUser = profile
            }
        }
    }

    // MARK: - Style Preferences

    private var preferencesSection: some View {
        Section("Style Preferences") {
            if let prefs = appState.currentUser?.stylePreferences {
                if let families = prefs.favoriteArchetypeFamilies, !families.isEmpty {
                    preferenceRow(label: "Families", values: families.map(\.capitalized))
                }
                if let occasions = prefs.preferredOccasions, !occasions.isEmpty {
                    preferenceRow(label: "Occasions", values: occasions.map(\.capitalized))
                }
            } else {
                Text("No preferences set")
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Button {
                showPreferencesEditor = true
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color(Theme.Colors.primary))
                    Text("Edit Preferences")
                        .foregroundStyle(Color(Theme.Colors.primary))
                }
            }
        }
    }

    // Build 27 — same `String` → `LocalizedStringResource` fix as
    // `statRow`. `label` is the chrome ("Families" / "Occasions");
    // `values` stays `String` because it's the user's DB-driven
    // preference list ("Streetwear, Edgy, Classic") — those are
    // raw archetype names and aren't localized today.
    private func preferenceRow(label: LocalizedStringResource, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            Text(values.joined(separator: ", "))
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle(isOn: $notificationsEnabled) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "bell")
                        .foregroundStyle(Color(Theme.Colors.primary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily Reminder")
                            .font(Theme.Fonts.body)
                        Text("Get notified when outfits are ready")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
                }
            }
            .tint(Color(Theme.Colors.primary))
            .onChange(of: notificationsEnabled) { _, newValue in
                Task {
                    let result = await NotificationService.shared.toggle(enabled: newValue)
                    if result != newValue {
                        notificationsEnabled = result
                    }
                }
            }
        }
    }

    // MARK: - Language (build 15)

    /// Build 15 — in-app language picker. Writing through
    /// `LanguageManager.set(_:)` updates the `AppleLanguages`
    /// UserDefaults entry; the change takes effect at next launch
    /// (same as iOS's own per-app picker in Settings.app). We
    /// surface a "Restart the app to apply" hint after a change
    /// instead of trying to swap the localization bundle live —
    /// the bundle swizzle hacks people post for this are fragile
    /// and a launch is cheap.
    private var languageSection: some View {
        Section("Language") {
            Picker(selection: $selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.localizedName).tag(language)
                }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(Theme.Colors.primary))
                        .frame(width: 20)
                    Text("Language")
                        .font(Theme.Fonts.body)
                }
            }
            .onChange(of: selectedLanguage) { _, newValue in
                LanguageManager.set(newValue)
                HapticManager.selection()
                showLanguageRestartHint = true
            }

            if showLanguageRestartHint {
                Text("Restart the app to apply the new language.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section("Image Cache") {
            HStack {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(Theme.Colors.primary))
                        .frame(width: 20)
                    Text("Disk Usage")
                        .font(Theme.Fonts.body)
                }
                Spacer()
                Text(cacheSize)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Button(role: .destructive) {
                Task {
                    isClearingCache = true
                    ImageCacheService.clearCache()
                    cacheSize = await ImageCacheService.formattedDiskCacheSize()
                    isClearingCache = false
                    HapticManager.success()
                }
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(isClearingCache ? "Clearing..." : "Clear Image Cache")
                }
            }
            .disabled(isClearingCache)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
        }
    }

    // MARK: - Developer (DEBUG-only)

    #if DEBUG
    private var developerSection: some View {
        Section("Developer") {
            NavigationLink {
                DeveloperMenuView()
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "hammer")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(Theme.Colors.primary))
                        .frame(width: 20)
                    Text("Developer Menu")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))
                }
            }
        }
    }
    #endif

    // MARK: - Sign Out

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await appState.signOut() }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign Out")
                }
            }
        }
    }

    // MARK: - Load Stats

    private func loadStats() async {
        guard let userId = appState.currentUser?.id else { return }
        isLoadingStats = true
        defer { isLoadingStats = false }

        do {
            let items = try await wardrobeRepository.fetchItems(userId: userId)
            let outfits = try await outfitRepository.fetchOutfits(userId: userId, limit: 1000)

            let categoryGroups = Dictionary(grouping: items, by: \.category)
            let mostWorn = categoryGroups.max(by: {
                $0.value.reduce(0) { $0 + $1.wearCount } <
                    $1.value.reduce(0) { $0 + $1.wearCount }
            })

            // Build 27 — store the category enum, not the
            // displayName. See `ProfileStats.mostWornCategory`.
            stats = ProfileStats(
                totalItems: items.count,
                outfitsGenerated: outfits.count,
                itemsWorn: items.filter { $0.wearCount > 0 }.count,
                mostWornCategory: mostWorn?.value.first(where: { $0.wearCount > 0 }) != nil
                    ? mostWorn?.key : nil
            )
        } catch {
            // Stats are non-critical — fail silently
        }
    }
}

// MARK: - Stats Model

private struct ProfileStats {
    var totalItems = 0
    var outfitsGenerated = 0
    var itemsWorn = 0
    // Build 27 — was `String?` (storing the category's English
    // displayName at fetch time), which baked in English even
    // under Turkish locale. Storing the enum lets the renderer
    // resolve `localizedName` at display time so the row reads
    // "Üst Giyim" in tr without an extra catalog round-trip.
    var mostWornCategory: ClothingCategory?
}

// MARK: - Style Preferences Editor

struct StylePreferencesEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFamilies: Set<String> = []
    @State private var selectedOccasions: Set<String> = []
    @State private var isSaving = false

    private let userRepository = UserRepository()

    private let allFamilies = [
        "classic", "minimalist", "romantic", "bohemian",
        "streetwear", "preppy", "edgy", "athleisure", "transitional",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Families
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Style Families")
                        .font(Theme.Fonts.h3)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))

                    Text("Select the styles you gravitate toward.")
                        .font(Theme.Fonts.bodySmall)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))

                    FlowLayoutOnboarding(spacing: Theme.Spacing.sm) {
                        ForEach(allFamilies, id: \.self) { family in
                            // Build 27 — `family` is a raw DB string
                            // ("streetwear", "edgy", ...) — not a
                            // catalog key yet. Wrap in
                            // `LocalizedStringResource(...)` via
                            // interpolation so the API matches
                            // `toggleChip`'s `LocalizedStringResource`
                            // signature. Family names will fall back
                            // to their capitalized raw value until a
                            // future build adds per-family catalog
                            // entries.
                            toggleChip(LocalizedStringResource("\(family.capitalized)"), isSelected: selectedFamilies.contains(family)) {
                                if selectedFamilies.contains(family) {
                                    selectedFamilies.remove(family)
                                } else {
                                    selectedFamilies.insert(family)
                                }
                            }
                        }
                    }
                }

                // Occasions
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Usual Occasions")
                        .font(Theme.Fonts.h3)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))

                    FlowLayoutOnboarding(spacing: Theme.Spacing.sm) {
                        ForEach(Occasion.allCases, id: \.self) { occasion in
                            // Build 27 — was `occasion.displayName`
                            // (raw English); now `localizedName`
                            // routes through the catalog.
                            toggleChip(occasion.localizedName, isSelected: selectedOccasions.contains(occasion.rawValue)) {
                                if selectedOccasions.contains(occasion.rawValue) {
                                    selectedOccasions.remove(occasion.rawValue)
                                } else {
                                    selectedOccasions.insert(occasion.rawValue)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle("Edit Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
                .fontWeight(.medium)
            }
        }
        .onAppear { loadExisting() }
    }

    // Build 27 — `title: String` → `LocalizedStringResource`.
    // Call sites pass either string literals ("Family X" — auto-
    // coerced) or `occasion.localizedName` for the Occasions row,
    // both of which route through the catalog.
    private func toggleChip(_ title: LocalizedStringResource, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(isSelected ? .white : Color(Theme.Colors.textPrimary))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(isSelected ? Color(Theme.Colors.primary) : Color(Theme.Colors.surface))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color(Theme.Colors.border), lineWidth: 1)
                )
        }
        .animation(Theme.Animation.standard, value: isSelected)
    }

    private func loadExisting() {
        if let prefs = appState.currentUser?.stylePreferences {
            selectedFamilies = Set(prefs.favoriteArchetypeFamilies ?? [])
            selectedOccasions = Set(prefs.preferredOccasions ?? [])
        }
    }

    private func save() async {
        guard let userId = appState.currentUser?.id else { return }
        isSaving = true
        defer { isSaving = false }

        let prefs = StylePreferences(
            favoriteArchetypeFamilies: selectedFamilies.isEmpty ? nil : Array(selectedFamilies),
            preferredOccasions: selectedOccasions.isEmpty ? nil : Array(selectedOccasions),
            avoidColors: appState.currentUser?.stylePreferences?.avoidColors
        )

        do {
            try await userRepository.updateStylePreferences(userId: userId, preferences: prefs)
            await appState.refreshProfile()
            dismiss()
        } catch {
            // Stay on page if save fails
        }
    }
}

#Preview {
    NavigationStack {
        ProfileView()
    }
    .environment(AppState())
}
