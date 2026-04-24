import SwiftUI

/// Developer-only surface that exposes the multi-garment inference
/// telemetry captured by `MLDiagnosticsStore`. Reached from
/// `DeveloperMenuView → ML Diagnostics`.
///
/// **Who sees this.** Build-gated to DEBUG + wrapped in the developer
/// menu that's already DEBUG-only in `ProfileView`. Production users
/// never reach this screen, and its data is in-memory only so there's
/// no privacy footprint.
///
/// **Why this exists.** When the user reports "it's slow" or "it missed
/// my jacket", this screen replaces several diagnostic round-trips: the
/// smoke-test status tells us whether Core ML loaded at all; the latency
/// histogram + inferred compute unit tells us whether ANE residency is
/// holding; the last-N predictions show the raw Fashionpedia class
/// labels so we can spot class-map drift before a user does.
struct MLDiagnosticsView: View {

    private let store = MLDiagnosticsStore.shared

    var body: some View {
        List {
            smokeTestSection
            summarySection
            recordsSection
        }
        .navigationTitle("ML Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var smokeTestSection: some View {
        Section {
            HStack {
                Text("Status")
                    .font(Theme.Fonts.body)
                Spacer()
                Text(smokeTestDescription)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(smokeTestTint)
            }
        } header: {
            Text("App-Launch Smoke Test")
        } footer: {
            Text("Runs once at launch in DEBUG builds. If the model throws, the multi-garment feature flag auto-disables so users never see a broken state.")
        }
    }

    private var summarySection: some View {
        Section("Current Snapshot") {
            infoRow("Model", value: store.records.first?.modelName ?? MultiGarmentProposalService.bundledModelName)
            infoRow("Feature flag", value: FeatureFlags.isMultiGarmentEnabled ? "ENABLED" : "disabled")
            infoRow("Compute unit", value: store.inferredComputeUnit)
            infoRow("Median latency", value: medianLatencyDescription)
            infoRow("Runs recorded", value: "\(store.records.count) / \(MLDiagnosticsStore.maxRecords)")
        }
    }

    @ViewBuilder
    private var recordsSection: some View {
        if store.records.isEmpty {
            Section("Recent Inferences") {
                Text("No inferences yet. Capture a photo with multi-garment detection enabled to populate this list.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
        } else {
            Section("Recent Inferences") {
                ForEach(store.records) { record in
                    recordRow(record)
                }
            }
        }
    }

    // MARK: - Row builders

    private func recordRow(_ record: MLDiagnosticsStore.InferenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                Text(String(format: "%.0f ms", record.latencyMs))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(record.threw ? Color.red : Color(Theme.Colors.textSecondary))
            }
            HStack {
                Image(systemName: record.threw ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(record.threw ? Color.red : Color.green)
                    .font(.caption)
                Text(record.threw
                     ? "Threw"
                     : "\(record.proposalCount) proposals")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Color(Theme.Colors.textSecondary))
            }
            if !record.topPredictions.isEmpty {
                ForEach(Array(record.topPredictions.enumerated()), id: \.offset) { index, prediction in
                    HStack {
                        Text("#\(index + 1)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                        Text(prediction.rawClass)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Text(String(format: "%.2f", prediction.score))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(Theme.Colors.textSecondary))
                    }
                }
            }
        }
        .padding(.vertical, 4)
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

    // MARK: - Derivations

    private var smokeTestDescription: String {
        switch store.smokeTestStatus {
        case .notRun:
            return "not run"
        case .running:
            return "running…"
        case .passed(let latency):
            return String(format: "passed (%.0f ms)", latency)
        case .skipped(let reason):
            return "skipped — \(reason)"
        case .failed(let reason):
            return "failed — \(reason)"
        }
    }

    private var smokeTestTint: Color {
        switch store.smokeTestStatus {
        case .notRun, .running:
            return Color(Theme.Colors.textSecondary)
        case .passed:
            return .green
        case .skipped:
            return .orange
        case .failed:
            return .red
        }
    }

    private var medianLatencyDescription: String {
        guard let median = store.medianLatencyMs else { return "—" }
        return String(format: "%.0f ms", median)
    }
}

#Preview {
    NavigationStack {
        MLDiagnosticsView()
    }
}
