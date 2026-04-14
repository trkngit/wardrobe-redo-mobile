import SwiftUI

// MARK: - Item Card Shimmer

/// Placeholder that mimics ItemCardView's layout during loading.
struct ItemCardShimmer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image placeholder
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(Theme.Colors.muted).opacity(0.15))
                .frame(minHeight: 160)
                .shimmer()

            // Metadata placeholder
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color(Theme.Colors.muted).opacity(0.2))
                            .frame(width: 10, height: 10)
                    }
                    Spacer()
                }

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(Theme.Colors.muted).opacity(0.2))
                    .frame(width: 60, height: 10)
                    .shimmer()
            }
            .padding(Theme.Spacing.sm)
        }
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
    }
}

/// Grid of shimmer placeholders matching the wardrobe grid layout.
struct WardrobeGridShimmer: View {
    let count: Int

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            ForEach(0..<count, id: \.self) { _ in
                ItemCardShimmer()
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
}

// MARK: - Outfit Card Shimmer

/// Placeholder that mimics OutfitCardView's layout during loading.
struct OutfitCardShimmer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(Theme.Colors.muted).opacity(0.2))
                        .frame(width: 180, height: 18)
                        .shimmer()

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(Theme.Colors.muted).opacity(0.15))
                        .frame(width: 220, height: 12)
                }
                Spacer()
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(Color(Theme.Colors.muted).opacity(0.15))
                    .frame(width: 40, height: 28)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)

            // Thumbnail strip
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(spacing: Theme.Spacing.xs) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(Theme.Colors.muted).opacity(0.15))
                            .frame(width: 80, height: 100)
                            .shimmer()

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(Theme.Colors.muted).opacity(0.1))
                            .frame(width: 40, height: 8)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)

            // Footer
            HStack {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle()
                            .fill(Color(Theme.Colors.muted).opacity(0.15))
                            .frame(width: 8, height: 8)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.md)
        }
        .background(Color(Theme.Colors.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .cardShadow()
    }
}

// MARK: - Previews

#Preview("Item Card Shimmer") {
    ItemCardShimmer()
        .frame(width: 180)
        .padding()
}

#Preview("Wardrobe Grid Shimmer") {
    WardrobeGridShimmer(count: 6)
        .padding()
}

#Preview("Outfit Card Shimmer") {
    OutfitCardShimmer()
        .padding()
}
