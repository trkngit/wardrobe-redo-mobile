import SwiftUI

/// 5-step onboarding: Welcome → Style Preferences → Vibe →
/// First Upload → Preview. Completes by marking
/// `onboarding_completed` in the user's profile and persisting
/// `default_vibe` if the user picked one different from the
/// `.balanced` default.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentStep = 0
    @State private var selectedFamilies: Set<String> = []
    @State private var selectedOccasions: Set<Occasion> = [.casual]
    @State private var selectedVibe: VibeStop = .balanced
    @State private var isSaving = false

    private let totalSteps = 5
    private let userRepository = UserRepository()

    var body: some View {
        ZStack {
            Color(Theme.Colors.background)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                progressBar
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.md)

                // Step content
                TabView(selection: $currentStep) {
                    welcomeStep.tag(0)
                    preferencesStep.tag(1)
                    vibeStep.tag(2)
                    uploadStep.tag(3)
                    previewStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(Theme.Animation.standard, value: currentStep)

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xl)
            }
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<totalSteps, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        step <= currentStep
                            ? Color(Theme.Colors.primary)
                            : Color(Theme.Colors.muted).opacity(0.3)
                    )
                    .frame(height: 3)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color(Theme.Colors.primary))

            VStack(spacing: Theme.Spacing.md) {
                Text("Welcome to\nWardrobe")
                    .font(Theme.Fonts.display)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .multilineTextAlignment(.center)

                Text("Your personal style engine — curating\ndaily outfits from your wardrobe using\n7 dimensions of style theory.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Step 2: Style Preferences

    private var preferencesStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Your Style")
                        .font(Theme.Fonts.h1)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))

                    Text("Select the style families that resonate with you. This helps us curate better outfits.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }

                // Style families
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Style Families")
                        .font(Theme.Fonts.h3)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))

                    FlowLayoutOnboarding(spacing: Theme.Spacing.sm) {
                        ForEach(styleFamilies, id: \.self) { family in
                            familyChip(family)
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
                            occasionChip(occasion)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private func familyChip(_ family: String) -> some View {
        let isSelected = selectedFamilies.contains(family)
        return Button {
            if isSelected {
                selectedFamilies.remove(family)
            } else {
                selectedFamilies.insert(family)
            }
        } label: {
            Text(family.capitalized)
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

    private func occasionChip(_ occasion: Occasion) -> some View {
        let isSelected = selectedOccasions.contains(occasion)
        return Button {
            if isSelected {
                selectedOccasions.remove(occasion)
            } else {
                selectedOccasions.insert(occasion)
            }
        } label: {
            Text(occasion.displayName)
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

    // MARK: - Step 3: Upload

    private var uploadStep: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color(Theme.Colors.primary))

            VStack(spacing: Theme.Spacing.md) {
                Text("Build Your Wardrobe")
                    .font(Theme.Fonts.h1)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Text("Take photos of your clothes to get started.\nWe'll analyze colors, textures, and formality\nautomatically.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            VStack(spacing: Theme.Spacing.sm) {
                tipRow(icon: "paintpalette", text: "Colors extracted automatically")
                tipRow(icon: "square.stack.3d.up", text: "7-dimension style scoring")
                tipRow(icon: "sparkles", text: "3 outfits generated daily")
            }
            .padding(.horizontal, Theme.Spacing.xxl)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color(Theme.Colors.primary))
                .frame(width: 24)

            Text(text)
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            Spacer()
        }
    }

    // MARK: - Step 4: Preview

    private var previewStep: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color(Theme.Colors.primary))

            VStack(spacing: Theme.Fonts.body == Theme.Fonts.body ? Theme.Spacing.md : Theme.Spacing.md) {
                Text("You're All Set")
                    .font(Theme.Fonts.h1)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Text("Start adding items to your wardrobe\nand we'll curate your first outfits.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                previewFeature(icon: "tshirt", title: "Wardrobe", desc: "Upload and organize your clothes")
                previewFeature(icon: "sparkles", title: "Daily Outfits", desc: "3 styled suggestions each day")
                previewFeature(icon: "arrow.triangle.branch", title: "Match", desc: "Find what goes with any item")
            }
            .padding(.horizontal, Theme.Spacing.lg)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func previewFeature(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color(Theme.Colors.primary))
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                Text(desc)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }

            Spacer()
        }
    }

    // MARK: - Step 3: Vibe (build 6)

    private var vibeStep: some View {
        VStack(spacing: Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "slider.horizontal.below.square.and.square.filled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color(Theme.Colors.primary))

                Text("Pick your default vibe")
                    .font(Theme.Fonts.h2)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .multilineTextAlignment(.center)

                Text("Where should the engine start when you tap Generate? You can always slide between Safe and Bold on the Outfits screen.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .lineSpacing(3)
            }
            .padding(.top, Theme.Spacing.lg)

            VibeSelector(vibe: $selectedVibe)
                .padding(.horizontal, Theme.Spacing.lg)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(selectedVibe.description)
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(Theme.Colors.surface))
                    )
            }
            .padding(.horizontal, Theme.Spacing.lg)

            Spacer()
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack(spacing: Theme.Spacing.md) {
            if currentStep > 0 {
                GhostButton("Back") {
                    currentStep -= 1
                }
            }

            if currentStep < totalSteps - 1 {
                GoldButton("Next") {
                    currentStep += 1
                }
            } else {
                GoldButton("Get Started", isLoading: isSaving) {
                    Task { await completeOnboarding() }
                }
            }
        }
    }

    // MARK: - Complete Onboarding

    private func completeOnboarding() async {
        guard let userId = appState.currentUser?.id else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            // Save preferences
            let preferences = StylePreferences(
                favoriteArchetypeFamilies: selectedFamilies.isEmpty ? nil : Array(selectedFamilies),
                preferredOccasions: selectedOccasions.isEmpty ? nil : selectedOccasions.map(\.rawValue),
                avoidColors: nil
            )
            try await userRepository.updateStylePreferences(userId: userId, preferences: preferences)

            // Build 6: persist the picked default vibe. We always
            // write this so the user's onboarding choice survives
            // even when they picked `.balanced` explicitly (their
            // intent — not a "user didn't pick" default).
            try await userRepository.updateDefaultVibe(userId: userId, vibe: selectedVibe)
            VibeTelemetry.logDefaultChanged(to: selectedVibe, via: "onboarding")

            // Mark onboarding completed
            try await userRepository.completeOnboarding(userId: userId)

            // Refresh profile in AppState
            await appState.refreshProfile()
        } catch {
            // Best effort — continue to app even if save fails
            await appState.refreshProfile()
        }
    }

    // MARK: - Data

    private let styleFamilies = [
        "classic", "minimalist", "romantic", "bohemian",
        "streetwear", "preppy", "edgy", "athleisure", "transitional",
    ]
}

// MARK: - Simple Flow Layout for Onboarding

/// Lightweight wrapping layout for onboarding chips.
struct FlowLayoutOnboarding: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}
