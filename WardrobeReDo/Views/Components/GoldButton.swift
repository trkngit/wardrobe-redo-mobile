import SwiftUI

struct GoldButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    init(_ title: String, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(Theme.Colors.primary))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
        }
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1)
    }
}

struct GhostButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(Theme.Colors.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .stroke(Color(Theme.Colors.primary), lineWidth: 1)
                )
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        GoldButton("Sign In") {}
        GoldButton("Loading...", isLoading: true) {}
        GhostButton("Create Account") {}
    }
    .padding()
}
