import SwiftUI

/// Hidden developer menu surfaced only in DEBUG builds. Host for
/// feature-flag toggles + diagnostic tooling that we don't want users
/// to see in production.
///
/// Reachable from `ProfileView`. Build-gated (`#if DEBUG`) so the
/// section is stripped from App Store binaries.
struct DeveloperMenuView: View {
    @State private var multiGarmentEnabled: Bool = FeatureFlags.isMultiGarmentEnabled

    var body: some View {
        List {
            experimentalFeaturesSection
            aboutSection
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var experimentalFeaturesSection: some View {
        Section {
            Toggle(isOn: $multiGarmentEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multi-Garment Detection")
                        .font(Theme.Fonts.body)
                    Text("Detect multiple clothing items in one photo and present them as selectable proposals.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }
            .tint(Color(Theme.Colors.primary))
            .onChange(of: multiGarmentEnabled) { _, newValue in
                FeatureFlags.isMultiGarmentEnabled = newValue
            }
        } header: {
            Text("Experimental Features")
        } footer: {
            Text("These toggles are only available in developer builds. Toggling a flag takes effect the next time a photo is processed.")
        }
    }

    private var aboutSection: some View {
        Section("Build Info") {
            infoRow("Build config", value: Self.buildConfigurationName)
            infoRow("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
            infoRow("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            infoRow("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Color(Theme.Colors.textPrimary))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(Theme.Colors.textSecondary))
        }
    }

    private static var buildConfigurationName: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }
}

#Preview {
    NavigationStack {
        DeveloperMenuView()
    }
}
