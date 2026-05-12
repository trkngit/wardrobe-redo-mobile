import SwiftUI
import Kingfisher

/// Full detail view for a single outfit: score breakdown bars,
/// item gallery, reaction buttons, and "mark as worn" toggle.
struct OutfitDetailView: View {
    let outfitId: UUID
    @Bindable var viewModel: OutfitViewModel

    private var dailyOutfit: DailyOutfit? {
        viewModel.dailyOutfits.first { $0.id == outfitId }
    }
    private var outfit: Outfit { dailyOutfit?.outfit ?? placeholderOutfit }
    private var items: [WardrobeItem] { dailyOutfit?.items ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // MARK: - Editorial Header
                editorialHeader

                // MARK: - Item Gallery
                itemGallery

                // MARK: - Score Breakdown
                scoreBreakdownSection

                // MARK: - Reactions
                reactionBar

                // MARK: - Mark as Worn
                wornToggle
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xxl)
            // Build 13 — parity with the build-10 carousel card.
            // A skipped outfit dims in the carousel; tapping into
            // the detail view shouldn't suddenly restore full
            // saturation as if the skip didn't happen. Same
            // numbers (0.45 opacity / 0.4 saturation) so the
            // transition into / out of detail feels continuous.
            // Applied to the content VStack instead of the
            // ScrollView so the toolbar share button stays at
            // full opacity for the action affordance.
            .opacity(isSkipped ? 0.45 : 1.0)
            .saturation(isSkipped ? 0.4 : 1.0)
            .animation(Theme.Animation.standard, value: isSkipped)
        }
        .background(Color(Theme.Colors.background))
        .navigationTitle(outfit.editorialName)
        .navigationBarTitleDisplayMode(.inline)
        // Build 11 — share affordance in the nav bar. Uses
        // SwiftUI's `ShareLink` so we get the standard iOS share
        // sheet (Messages / Mail / AirDrop / WhatsApp / Notes /
        // ...) for free instead of hand-rolling
        // UIActivityViewController. Shares the editorial copy +
        // a per-item breakdown — text-only on purpose, since the
        // visual is hard to reproduce reliably without screenshot
        // capture. A future iteration can attach a rendered card.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(Theme.Colors.primary))
                }
                .accessibilityLabel("Share outfit")
            }
        }
    }

    /// Build 13 — same skip predicate as `OutfitCardView`.
    /// Drives the dim + desaturation treatment so a skipped
    /// outfit looks visibly de-prioritized in both the carousel
    /// and the detail view.
    private var isSkipped: Bool { outfit.reaction == "skip" }

    /// Build 11 — text representation of the outfit for the
    /// share sheet. Keeps it short enough to fit in a single
    /// iMessage bubble while still naming every piece. Score is
    /// rounded to a percentage because no recipient outside the
    /// app reads raw 0.0–1.0 floats. Includes a soft brand
    /// signature so the receiver can find the app if they care.
    private var shareText: String {
        var lines: [String] = []
        lines.append(outfit.editorialName)
        if let description = outfit.editorialDescription, !description.isEmpty {
            lines.append(description)
        }
        if !items.isEmpty {
            lines.append("")
            for item in items {
                lines.append("• \(item.subcategory.displayName)")
            }
        }
        lines.append("")
        lines.append("Score: \(Int(outfit.score * 100))%")
        lines.append("— Curated with Wardrobe")
        return lines.joined(separator: "\n")
    }

    // MARK: - Editorial Header

    private var editorialHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(outfit.editorialName)
                        .font(Theme.Fonts.h1)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))

                    if let description = outfit.editorialDescription {
                        Text(description)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
                }

                Spacer()

                totalScoreBadge
            }
        }
        .padding(.top, Theme.Spacing.sm)
    }

    // MARK: - Total Score Badge

    private var totalScoreBadge: some View {
        VStack(spacing: 2) {
            Text("\(Int(outfit.score * 100))")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color(Theme.Colors.primary))

            Text("Score")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
        .padding(Theme.Spacing.md)
        .background(Color(Theme.Colors.primaryMuted).opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    // MARK: - Item Gallery

    private var itemGallery: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Items")
                .font(Theme.Fonts.h3)
                .foregroundStyle(Color(Theme.Colors.textPrimary))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                ForEach(items) { item in
                    itemCard(for: item)
                }
            }
        }
    }

    private func itemCard(for item: WardrobeItem) -> some View {
        let slot = dailyOutfit?.slots.first { $0.wardrobeItemId == item.id }

        return VStack(spacing: Theme.Spacing.xs) {
            KFImage(viewModel.thumbnailURLs[item.id])
                .placeholder {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(Theme.Colors.muted).opacity(0.3))
                        .overlay {
                            Image(systemName: item.category.iconName)
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(Color(Theme.Colors.textSecondary))
                        }
                }
                .resizable()
                .scaledToFill()
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Build 17 — localized subcategory in detail gallery.
            Text(item.subcategory.localizedName)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
                .lineLimit(1)

            if let role = slot?.role {
                Text(role.capitalized)
                    .font(Theme.Fonts.overline)
                    .foregroundStyle(
                        role == "hero"
                            ? Color(Theme.Colors.primary)
                            : Color(Theme.Colors.textSecondary)
                    )
            }

            // Color dots
            HStack(spacing: 2) {
                ForEach(Array(item.dominantColors.prefix(3).enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    // MARK: - Score Breakdown

    private var scoreBreakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Style Analysis")
                .font(Theme.Fonts.h3)
                .foregroundStyle(Color(Theme.Colors.textPrimary))

            if let breakdown = outfit.scoreBreakdown {
                VStack(spacing: Theme.Spacing.sm) {
                    dimensionBar(label: "Proportion", value: breakdown.proportion, weight: 0.15)
                    dimensionBar(label: "Color", value: breakdown.colorHarmony, weight: 0.25)
                    dimensionBar(label: "Texture", value: breakdown.textureMix, weight: 0.10)
                    dimensionBar(label: "Formality", value: breakdown.formality, weight: 0.15)
                    dimensionBar(label: "Formula", value: breakdown.formula, weight: 0.15)
                    dimensionBar(label: "Versatility", value: breakdown.versatility, weight: 0.10)
                    dimensionBar(label: "Context", value: breakdown.occasion, weight: 0.10)
                }
                .padding(Theme.Spacing.md)
                .background(Color(Theme.Colors.surface))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else {
                Text("Score breakdown not available")
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
        }
    }

    private func dimensionBar(label: String, value: Double, weight: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(Theme.Fonts.bodySmall)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Spacer()

                Text("\(Int(value * 100))%")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))

                Text("(\(Int(weight * 100))w)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary).opacity(0.6))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(Theme.Colors.muted).opacity(0.15))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(for: value))
                        .frame(width: geo.size.width * min(1.0, max(0.0, value)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // Fallback for when the outfit hasn't been found yet (shouldn't happen in practice)
    private var placeholderOutfit: Outfit {
        Outfit(
            id: outfitId, userId: UUID(), archetypeId: UUID(),
            editorialName: "", editorialDescription: nil,
            date: "", score: 0, scoreBreakdown: nil,
            reaction: nil, isWorn: false, createdAt: Date()
        )
    }

    private func barColor(for value: Double) -> Color {
        if value >= 0.7 { return Color(Theme.Colors.primary) }
        if value >= 0.4 { return Color(Theme.Colors.primaryLight) }
        return Color(Theme.Colors.textSecondary)
    }

    // MARK: - Reaction Bar

    private var reactionBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("How do you feel about this outfit?")
                .font(Theme.Fonts.bodySmall)
                .foregroundStyle(Color(Theme.Colors.textSecondary))

            HStack(spacing: Theme.Spacing.md) {
                reactionButton(reaction: "love", icon: "heart.fill", label: "Love", activeColor: .red)
                reactionButton(reaction: "like", icon: "hand.thumbsup.fill", label: "Like", activeColor: Color(Theme.Colors.primary))
                reactionButton(reaction: "skip", icon: "forward.fill", label: "Skip", activeColor: Color(Theme.Colors.textSecondary))

                Spacer()
            }
        }
    }

    private func reactionButton(reaction: String, icon: String, label: String, activeColor: Color) -> some View {
        let isActive = outfit.reaction == reaction

        return Button {
            HapticManager.light()
            Task { await viewModel.react(outfitId: outfit.id, reaction: reaction) }
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isActive ? activeColor : Color(Theme.Colors.textSecondary).opacity(0.4))
                    .scaleEffect(isActive ? 1.15 : 1.0)

                Text(label)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(
                        isActive
                            ? activeColor
                            : Color(Theme.Colors.textSecondary)
                    )
            }
            .frame(width: 60, height: 56)
            .background(
                isActive
                    ? activeColor.opacity(0.08)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .animation(Theme.Animation.spring, value: isActive)
    }

    // MARK: - Worn Toggle

    private var wornToggle: some View {
        Button {
            HapticManager.medium()
            Task { await viewModel.toggleWorn(outfitId: outfit.id) }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: outfit.isWorn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        outfit.isWorn
                            ? Color(Theme.Colors.primary)
                            : Color(Theme.Colors.textSecondary)
                    )

                Text(outfit.isWorn ? "Worn today" : "Mark as worn")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))

                Spacer()
            }
            .padding(Theme.Spacing.md)
            .background(Color(Theme.Colors.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
    }
}
