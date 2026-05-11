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

    private let wardrobeRepository = WardrobeRepository()
    private let outfitRepository = OutfitRepository()

    var body: some View {
        List {
            userInfoSection
            statsSection
            defaultVibeSection
            preferencesSection
            notificationsSection
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
                statRow(label: "Most Worn", value: mostWorn, icon: "flame")
            }
        }
    }

    private func statRow(label: String, value: String, icon: String) -> some View {
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

    private func preferenceRow(label: String, values: [String]) -> some View {
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

            stats = ProfileStats(
                totalItems: items.count,
                outfitsGenerated: outfits.count,
                itemsWorn: items.filter { $0.wearCount > 0 }.count,
                mostWornCategory: mostWorn?.value.first(where: { $0.wearCount > 0 }) != nil
                    ? mostWorn?.key.displayName : nil
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
    var mostWornCategory: String?
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
                            toggleChip(family.capitalized, isSelected: selectedFamilies.contains(family)) {
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
                            toggleChip(occasion.displayName, isSelected: selectedOccasions.contains(occasion.rawValue)) {
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

    private func toggleChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
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
