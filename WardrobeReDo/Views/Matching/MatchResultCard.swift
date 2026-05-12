import SwiftUI
import Kingfisher

/// Compact card for a single match result: editorial name, score,
/// item thumbnails, and save button.
struct MatchResultCard: View {
    let candidate: OutfitCandidate
    let thumbnailURLs: [UUID: URL]
    let isSaved: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header: name + score
            header

            // Item thumbnail row
            itemRow

            // Footer: description + save button
            footer
        }
        .padding(Theme.Spacing.md)
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.editorialName)
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(Color(Theme.Colors.textPrimary))
                    .lineLimit(1)

                Text(candidate.archetype.family.capitalized)
                    .font(Theme.Fonts.overline)
                    .foregroundStyle(Color(Theme.Colors.primary))
                    .textCase(.uppercase)
            }

            Spacer()

            Text("\(Int(candidate.score.totalScore * 100))")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(Theme.Colors.primary))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Color(Theme.Colors.primaryMuted).opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
    }

    // MARK: - Item Row

    private var itemRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(candidate.items) { item in
                itemThumbnail(item)
            }
            Spacer()
        }
    }

    private func itemThumbnail(_ item: WardrobeItem) -> some View {
        let isHero = candidate.slots.first(where: { $0.item.id == item.id })?.role == "hero"

        return VStack(spacing: 2) {
            KFImage(thumbnailURLs[item.id])
                .placeholder {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(Theme.Colors.muted).opacity(0.3))
                        .overlay {
                            Image(systemName: item.category.iconName)
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(Color(Theme.Colors.textSecondary))
                        }
                }
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isHero ? Color(Theme.Colors.primary) : Color.clear,
                            lineWidth: 2
                        )
                )

            // Build 17 — localized subcategory.
            Text(item.subcategory.localizedName)
                .font(.system(size: 9))
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(candidate.editorialDescription)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Color(Theme.Colors.textSecondary))
                .lineLimit(2)

            Spacer()

            saveButton
        }
    }

    private var saveButton: some View {
        Button {
            HapticManager.light()
            onSave()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 13))
                Text(isSaved ? "Saved" : "Save")
                    .font(Theme.Fonts.bodySmall)
            }
            .foregroundStyle(isSaved ? Color(Theme.Colors.primary) : Color(Theme.Colors.textPrimary))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                isSaved
                    ? Color(Theme.Colors.primaryMuted).opacity(0.15)
                    : Color(Theme.Colors.muted).opacity(0.1)
            )
            .clipShape(Capsule())
        }
        .disabled(isSaved)
    }
}
