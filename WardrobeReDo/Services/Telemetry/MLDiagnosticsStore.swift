import Foundation
import Observation
import os.log

/// Observable singleton that captures recent multi-garment inference
/// telemetry for the `MLDiagnosticsView` developer surface.
///
/// When a user reports "the multi-pick screen is slow" or "it's missing
/// items", this store is the first stop: it shows the last N inferences'
/// latency, the inferred compute unit (ANE/GPU/CPU based on timing), the
/// app-launch smoke test status, and each run's top-3 raw class labels.
/// That replaces a several-back-and-forth diagnostic loop with a single
/// screenshot the user can send us.
///
/// **Scope.** Everything here is in-memory only. We deliberately do NOT
/// persist diagnostics to disk or phone-home — privacy-sensitive paths
/// like clothing photos must never leak by accident. A release-build
/// user will never see this screen, and if they do, there's nothing
/// sensitive in it.
@MainActor
@Observable
final class MLDiagnosticsStore {

    /// Shared instance. The store is a singleton because it's written to
    /// from the non-isolated `MultiGarmentProposalService` and read from
    /// a SwiftUI view — having one well-known access point avoids
    /// threading a dependency through both call sites.
    static let shared = MLDiagnosticsStore()

    /// Keep the last N inferences. Ten is enough to see a trend (latency
    /// regression, class-label drift) without unbounded memory growth.
    static let maxRecords = 10

    // MARK: - Types

    struct InferenceRecord: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let latencyMs: Double
        let proposalCount: Int
        /// Top-3 class / score pairs, zipped to avoid desync. Stored as a
        /// pair type instead of two parallel arrays so the view can't
        /// accidentally render class[0] against score[1].
        let topPredictions: [ClassScore]
        let modelName: String
        let threw: Bool

        struct ClassScore: Equatable, Hashable {
            let rawClass: String
            let score: Float
        }
    }

    enum SmokeTestStatus: Equatable {
        /// App hasn't yet launched a smoke test (release build, tests,
        /// or DEBUG smoke-test dispatch hasn't run yet).
        case notRun
        /// Smoke test is currently executing.
        case running
        /// Model ran successfully on the synthetic probe image.
        case passed(latencyMs: Double)
        /// Model file not present — expected path for local builds before
        /// the training run ships. Not a failure.
        case skipped(reason: String)
        /// Model ran but threw. The feature flag auto-disables in this
        /// case so users never see a broken state.
        case failed(reason: String)
    }

    // MARK: - State

    /// Most-recent-first ring buffer of the last `maxRecords` inferences.
    private(set) var records: [InferenceRecord] = []

    /// Result of the app-launch smoke test (debug builds only).
    private(set) var smokeTestStatus: SmokeTestStatus = .notRun

    private let logger = Logger(subsystem: "com.wardroberedo", category: "MLDiagnostics")

    // MARK: - Mutations

    /// Record a successful inference. Called from
    /// `MultiGarmentProposalService.detectProposals` after success.
    ///
    /// Also forwards a sanitized `MLTelemetryService.Observation` to the
    /// opt-in Supabase telemetry pipeline (gated on
    /// `FeatureFlags.isMLTelemetryEnabled`; no-ops when off). Fire-and-forget
    /// via `Task` — the upload failing or being skipped must never block
    /// the DEBUG diagnostic surface.
    func record(
        latencyMs: Double,
        proposals: [MaskProposal],
        modelName: String
    ) {
        let top = proposals.prefix(3).map { proposal in
            InferenceRecord.ClassScore(
                rawClass: proposal.modelClassRaw,
                score: proposal.detectionScore
            )
        }
        let entry = InferenceRecord(
            id: UUID(),
            timestamp: Date(),
            latencyMs: latencyMs,
            proposalCount: proposals.count,
            topPredictions: Array(top),
            modelName: modelName,
            threw: false
        )
        insertAndTrim(entry)

        let observation = MLTelemetryService.Observation(
            modelName: modelName,
            surface: Self.surface(for: modelName),
            latencyMs: latencyMs,
            computeUnit: Self.inferredComputeUnit(forLatencyMs: latencyMs),
            proposalCount: proposals.count,
            topClassRaw: top.first?.rawClass,
            topScore: top.first?.score,
            threw: false
        )
        Task { await MLTelemetryService.shared.logInference(observation) }
    }

    /// Record a failed inference. Keeps the failure in the timeline so
    /// developers can see how often the model is throwing and why.
    /// Same telemetry forwarding posture as the success path.
    func recordFailure(
        latencyMs: Double,
        modelName: String
    ) {
        let entry = InferenceRecord(
            id: UUID(),
            timestamp: Date(),
            latencyMs: latencyMs,
            proposalCount: 0,
            topPredictions: [],
            modelName: modelName,
            threw: true
        )
        insertAndTrim(entry)

        let observation = MLTelemetryService.Observation(
            modelName: modelName,
            surface: Self.surface(for: modelName),
            latencyMs: latencyMs,
            computeUnit: Self.inferredComputeUnit(forLatencyMs: latencyMs),
            proposalCount: 0,
            topClassRaw: nil,
            topScore: nil,
            threw: true
        )
        Task { await MLTelemetryService.shared.logInference(observation) }
    }

    func setSmokeTestStatus(_ status: SmokeTestStatus) {
        smokeTestStatus = status
        logger.info("smokeTestStatus -> \(String(describing: status), privacy: .public)")
    }

    /// Wipe all telemetry. Exposed for tests and a future "Clear" button.
    func resetAll() {
        records.removeAll(keepingCapacity: true)
        smokeTestStatus = .notRun
    }

    // MARK: - Derived helpers

    /// Rough heuristic mapping latency to likely compute unit. Meant as a
    /// developer hint, not a contract — Apple doesn't expose compute-lane
    /// metadata at runtime, so this is inferred from timing on current
    /// hardware. iPhone 12+ ANE usually delivers under 250 ms for the
    /// model size we're shipping; GPU fallback lands in 250–900 ms; CPU
    /// fallback is almost always > 900 ms.
    var inferredComputeUnit: String {
        guard let latest = records.first?.latencyMs else { return "—" }
        return Self.inferredComputeUnit(forLatencyMs: latest)
    }

    /// Static form of the compute-unit heuristic so telemetry callers can
    /// label an individual observation without reading the ring buffer
    /// (which may already have moved on by the time the `Task` fires).
    static func inferredComputeUnit(forLatencyMs latencyMs: Double) -> String {
        if latencyMs < 250 { return "ANE (likely)" }
        if latencyMs < 900 { return "GPU (likely)" }
        return "CPU (likely)"
    }

    /// Map a model name to a telemetry surface string. Matches the
    /// surfaces documented in migration 00011 (`multi_garment`,
    /// `attribute_classifier`). Keep this in sync with any new model we
    /// start recording — the free-form column intentionally allows new
    /// surfaces without a schema migration but the analysis dashboards
    /// pre-filter on these known values.
    static func surface(for modelName: String) -> String {
        let lower = modelName.lowercased()
        if lower.contains("attribute") { return "attribute_classifier" }
        return "multi_garment"
    }

    /// Median latency of recorded inferences, or nil if none recorded.
    var medianLatencyMs: Double? {
        let successful = records.filter { !$0.threw }.map(\.latencyMs).sorted()
        guard !successful.isEmpty else { return nil }
        let mid = successful.count / 2
        if successful.count % 2 == 0 {
            return (successful[mid - 1] + successful[mid]) / 2
        }
        return successful[mid]
    }

    // MARK: - Private

    private func insertAndTrim(_ entry: InferenceRecord) {
        records.insert(entry, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
    }
}
