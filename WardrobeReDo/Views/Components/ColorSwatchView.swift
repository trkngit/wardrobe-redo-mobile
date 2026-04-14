import SwiftUI

struct ColorSwatchView: View {
    let colors: [ColorProfile]
    var size: CGFloat = 24
    var showPercentage: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                VStack(spacing: Theme.Spacing.xs) {
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: size, height: size)
                        .overlay(
                            Circle()
                                .stroke(.white, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

                    if showPercentage {
                        Text("\(Int(color.percentage))%")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
                }
            }
        }
    }
}

struct ColorSwatchDetailView: View {
    let colors: [ColorProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                HStack(spacing: Theme.Spacing.md) {
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(.white, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(color.colorFamily.capitalized)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(Theme.Colors.textPrimary))
                        Text(color.hex)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }

                    Spacer()

                    Text("\(Int(color.percentage))%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        ColorSwatchView(
            colors: [
                ColorProfile(hex: "#2C3E50", hue: 210, saturation: 0.3, lightness: 0.25, percentage: 65, colorFamily: "navy", isNeutral: true),
                ColorProfile(hex: "#E74C3C", hue: 6, saturation: 0.78, lightness: 0.57, percentage: 22, colorFamily: "red", isNeutral: false),
                ColorProfile(hex: "#F5F5DC", hue: 60, saturation: 0.56, lightness: 0.91, percentage: 13, colorFamily: "cream", isNeutral: true),
            ],
            showPercentage: true
        )

        ColorSwatchDetailView(
            colors: [
                ColorProfile(hex: "#2C3E50", hue: 210, saturation: 0.3, lightness: 0.25, percentage: 65, colorFamily: "navy", isNeutral: true),
                ColorProfile(hex: "#E74C3C", hue: 6, saturation: 0.78, lightness: 0.57, percentage: 22, colorFamily: "red", isNeutral: false),
            ]
        )
        .padding()
    }
}
