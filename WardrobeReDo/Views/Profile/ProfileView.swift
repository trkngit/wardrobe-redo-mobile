import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            // User info section
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

            // Stats placeholder
            Section("Wardrobe Stats") {
                HStack {
                    Text("Total Items")
                    Spacer()
                    Text("0")
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
                HStack {
                    Text("Outfits Generated")
                    Spacer()
                    Text("0")
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }

            // Sign out
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
        .navigationTitle("Profile")
    }
}

#Preview {
    NavigationStack {
        ProfileView()
    }
    .environment(AppState())
}
