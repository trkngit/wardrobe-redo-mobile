import SwiftUI

/// Hidden developer menu surfaced only in DEBUG builds. Host for
/// feature-flag toggles + diagnostic tooling that we don't want users
/// to see in production.
///
/// Reachable from `ProfileView`. Build-gated (`#if DEBUG`) so the
/// section is stripped from App Store binaries.
///
/// ## Sections
///
/// - **Experimental Features** — opt-in toggles for the three gated
///   features (multi-garment detection, auto-attribute pre-fill, ML
///   inference telemetry). State persists in `UserDefaults` via
///   `FeatureFlags`.
/// - **Dogfood** — developer-initiated smoke + bug-report affordances.
///   Report-issue ShareLink compiles a plaintext diagnostic bundle
///   (build info, flag state, the last N ML inferences — no image
///   bytes) and hands it to the system share sheet. "Fire Sentry smoke
///   event" verifies the crash-reporting plumbing by submitting a
///   non-fatal message through `SentryService`.
/// - **Diagnostics** — read-only view of the ML inference ring buffer.
/// - **Build Info** — bundle version, build number, Debug/Release flag.
struct DeveloperMenuView: View {
    @State private var multiGarmentEnabled: Bool = FeatureFlags.isMultiGarmentEnabled
    @State private var attributeDetectionEnabled: Bool = FeatureFlags.isAttributeDetectionEnabled
    @State private var mlTelemetryEnabled: Bool = FeatureFlags.isMLTelemetryEnabled
    /// Transient confirmation / error text shown directly under the
    /// Sentry smoke button. Cleared on the next interaction so the UI
    /// doesn't turn into a stale log — users who want a history check
    /// the Sentry dashboard instead.
    @State private var smokeEventFeedback: String?

    var body: some View {
        List {
            experimentalFeaturesSection
            dogfoodSection
            diagnosticsSection
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

            Toggle(isOn: $attributeDetectionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Attribute Pre-fill")
                        .font(Theme.Fonts.body)
                    Text("Pre-select category, fit, seasons, and occasions after capture. Texture stays user-input until v1.1. Off → legacy hard-reset defaults.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }
            .tint(Color(Theme.Colors.primary))
            .onChange(of: attributeDetectionEnabled) { _, newValue in
                FeatureFlags.isAttributeDetectionEnabled = newValue
            }

            Toggle(isOn: $mlTelemetryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ML Inference Telemetry")
                        .font(Theme.Fonts.body)
                    Text("Upload latency, top class, and pre-fill correction flags to ml_inference_telemetry. No image bytes or crops are included.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }
            .tint(Color(Theme.Colors.primary))
            .onChange(of: mlTelemetryEnabled) { _, newValue in
                FeatureFlags.isMLTelemetryEnabled = newValue
            }
        } header: {
            Text("Experimental Features")
        } footer: {
            Text("These toggles are only available in developer builds. Toggling a flag takes effect the next time a photo is processed.")
        }
    }

    /// Dogfood affordances — see the Tier A1 plan's verification bullet:
    /// "Sentry smoke: trigger a caught event in DEBUG dev menu → event
    /// appears in Sentry dashboard within 60 s." The ShareLink is the
    /// structured bug-report channel so a user-hit issue lands with
    /// enough context to reproduce later.
    private var dogfoodSection: some View {
        Section {
            ShareLink(
                item: diagnosticsBundle,
                subject: Text("Wardrobe dogfood diagnostics")
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report issue (share diagnostics)")
                        .font(Theme.Fonts.body)
                    Text("Export a plaintext bundle with build info, flag state, and the last \(MLDiagnosticsStore.maxRecords) inferences. No image bytes are included.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }

            Button {
                let fired = SentryService.captureSmokeEvent(note: "developer menu")
                smokeEventFeedback = fired
                    ? "Smoke event sent. Check the Sentry dashboard within 60 s."
                    : "Sentry is disabled (no DSN in Secrets.plist) — event not sent."
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fire Sentry smoke event")
                        .font(Theme.Fonts.body)
                    Text("Submit a non-fatal test event to verify crash-reporting plumbing. Safe to call with or without a DSN.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }

            if let feedback = smokeEventFeedback {
                Text(feedback)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
        } header: {
            Text("Dogfood")
        } footer: {
            Text("Use these when something breaks in day-to-day use. The diagnostics bundle carries enough signal to reproduce an issue without leaking photo content.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                MLDiagnosticsView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ML Diagnostics")
                        .font(Theme.Fonts.body)
                    Text("Latency, compute unit, smoke-test status, and last 10 inferences.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(Theme.Colors.textSecondary))
                }
            }
        } header: {
            Text("Diagnostics")
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

    /// Compose the plaintext diagnostic bundle that the Report-issue
    /// ShareLink hands to the share sheet. Intentionally captures only
    /// signal that is safe to leave the device:
    /// - build metadata (version, bundle id, Debug vs Release)
    /// - feature-flag state (three toggles)
    /// - ML smoke-test status + median latency
    /// - per-inference log: timestamp, model, latency, top class + score,
    ///   threw flag — **no** image bytes, crops, or colors.
    ///
    /// String-based so SwiftUI's `ShareLink(item:)` can pass it through
    /// as a `Transferable` without custom UTIs.
    private var diagnosticsBundle: String {
        let store = MLDiagnosticsStore.shared
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let bundleId = Bundle.main.bundleIdentifier ?? "—"

        var lines: [String] = []
        lines.append("Wardrobe Re-Do — dogfood diagnostics")
        lines.append("———————————————————————————————")
        lines.append("Build config : \(Self.buildConfigurationName)")
        lines.append("Version      : \(version) (\(build))")
        lines.append("Bundle ID    : \(bundleId)")
        lines.append("Generated at : \(Self.timestampFormatter.string(from: Date()))")
        lines.append("")
        lines.append("Feature flags")
        lines.append("  multi-garment  : \(FeatureFlags.isMultiGarmentEnabled)")
        lines.append("  auto-attribute : \(FeatureFlags.isAttributeDetectionEnabled)")
        lines.append("  ml-telemetry   : \(FeatureFlags.isMLTelemetryEnabled)")
        lines.append("")
        lines.append("ML smoke test : \(String(describing: store.smokeTestStatus))")
        if let median = store.medianLatencyMs {
            lines.append("Median latency: \(String(format: "%.1f", median)) ms")
        } else {
            lines.append("Median latency: (no successful inferences recorded)")
        }
        lines.append("")
        lines.append("Last \(store.records.count) inferences (most recent first)")
        if store.records.isEmpty {
            lines.append("  (none)")
        } else {
            for record in store.records {
                let topLabel: String
                if let first = record.topPredictions.first {
                    topLabel = "\(first.rawClass) @ \(String(format: "%.2f", first.score))"
                } else {
                    topLabel = "—"
                }
                lines.append(
                    "  [\(Self.timestampFormatter.string(from: record.timestamp))] " +
                    "\(record.modelName) \(String(format: "%.0f", record.latencyMs))ms " +
                    "→ \(topLabel) (threw: \(record.threw))"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static var buildConfigurationName: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    /// ISO-like timestamp for the diagnostic bundle. Not `.iso8601` because
    /// the trailing timezone offset makes the line noisier than useful on
    /// a copy-paste surface; seconds-precision local time is enough.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

#Preview {
    NavigationStack {
        DeveloperMenuView()
    }
}
