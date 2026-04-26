import SwiftUI

/// Single editorial-colour view — the "1 hero colour + N accents" UI
/// described in `K-design-critique-redesign.md` §6. Replaces the
/// `ColorSwatchView(showPercentage: true)` panel in places where a
/// clean palette presentation matters (Add Item form, Item Detail).
///
/// Behaviour:
/// - 1 hero swatch (56pt circle) — large and prominent.
/// - Colour family name as the label (e.g. "Indigo").
/// - Hex code in caption-size text directly underneath.
/// - "+N more" expander reveals up to three smaller accent chips.
/// - Percentages are intentionally omitted — those numbers were
///   engineering data leaking into the product surface.
struct EditorialColorView: View {
    let colors: [ColorProfile]

    @State private var isExpanded = false

    var body: some View {
        if let hero = colors.first {
            let accents = Array(colors.dropFirst().prefix(3))

            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Circle()
                    .fill(Color(hex: hero.hex))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(hero.colorFamily.capitalized)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Color(Theme.Colors.textPrimary))
                    Text(hero.hex.uppercased())
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }

                Spacer(minLength: Theme.Spacing.sm)

                if !accents.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        if isExpanded {
                            HStack(spacing: 4) {
                                ForEach(Array(accents.enumerated()), id: \.offset) { _, accent in
                                    Circle()
                                        .fill(Color(hex: accent.hex))
                                        .frame(width: 18, height: 18)
                                        .overlay(
                                            Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5)
                                        )
                                }
                            }
                        } else {
                            Text("+\(accents.count) more")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Color(Theme.Colors.textSecondary))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            EmptyView()
        }
    }
}

#Preview("Hero + accents") {
    EditorialColorView(
        colors: [
            ColorProfile(hex: "#2C3E50", hue: 210, saturation: 0.3, lightness: 0.25, percentage: 65, colorFamily: "indigo", isNeutral: true),
            ColorProfile(hex: "#E74C3C", hue: 6, saturation: 0.78, lightness: 0.57, percentage: 22, colorFamily: "red", isNeutral: false),
            ColorProfile(hex: "#F5F5DC", hue: 60, saturation: 0.56, lightness: 0.91, percentage: 13, colorFamily: "cream", isNeutral: true),
        ]
    )
    .padding()
}

#Preview("Hero only") {
    EditorialColorView(
        colors: [
            ColorProfile(hex: "#2C3E50", hue: 210, saturation: 0.3, lightness: 0.25, percentage: 100, colorFamily: "indigo", isNeutral: true)
        ]
    )
    .padding()
}

#Preview("Empty") {
    EditorialColorView(colors: [])
        .padding()
}
