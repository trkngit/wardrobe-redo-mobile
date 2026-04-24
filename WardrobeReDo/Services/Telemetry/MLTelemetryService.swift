import Foundation
import OSLog
import Supabase
@preconcurrency import PostgREST

/// Opt-in telemetry for on-device Core ML inferences. Uploads one
/// row per inference into the `ml_inference_telemetry` table
/// (migration 00011) so we can observe fire rate, latency, and
/// correction rates across dogfooders without a hand-on-the-phone
/// diagnostic session.
///
/// **Privacy.** No image bytes, no crops, no colors — only timing,
/// the argmax class label, and whether the user corrected a
/// pre-fill. The full list of columns is in the migration header.
///
/// **Gating.** Reads `FeatureFlags.isMLTelemetryEnabled` on every
/// call. The flag defaults to `false`; when off, `logInference(...)`
/// returns synchronously without touching the network. No side
/// effects, no allocations beyond the closure capture.
///
/// **Concurrency.** Actor-isolated so we can batch upserts in a
/// future revision without reworking the call sites. For v1 each
/// call is a single INSERT — we rely on the Supabase client's
/// internal session management for connection reuse.
///
/// **Failure handling.** Fire-and-forget. A failed upload is logged
/// at `.info` level (not `.error` — losing a telemetry row is
/// expected and not actionable for the user) and swallowed. We
/// deliberately do NOT retry via `withRetry` — telemetry rows are
/// worth less than a network round-trip's worth of battery.
public actor MLTelemetryService {

    public static let shared = MLTelemetryService()

    private let log = Logger(subsystem: "com.wardroberedo", category: "MLTelemetry")
    private let supabase = SupabaseManager.shared.client

    // MARK: - Input

    /// Describes one inference, without the user identity — the
    /// service resolves the user from the Supabase auth session at
    /// upload time so callers don't have to thread `currentUser?.id`
    /// through every ML code path.
    public struct Observation: Sendable {
        public let modelName: String
        /// `"multi_garment"` or `"attribute_classifier"`, etc. Free-form
        /// so future models don't need a schema migration.
        public let surface: String
        public let latencyMs: Double
        public let computeUnit: String?
        public let proposalCount: Int?
        public let topClassRaw: String?
        public let topScore: Float?
        public let threw: Bool
        public let prefillFired: Bool?
        public let userCorrected: Bool?
        public let fieldChanged: String?

        public init(
            modelName: String,
            surface: String,
            latencyMs: Double,
            computeUnit: String? = nil,
            proposalCount: Int? = nil,
            topClassRaw: String? = nil,
            topScore: Float? = nil,
            threw: Bool = false,
            prefillFired: Bool? = nil,
            userCorrected: Bool? = nil,
            fieldChanged: String? = nil
        ) {
            self.modelName = modelName
            self.surface = surface
            self.latencyMs = latencyMs
            self.computeUnit = computeUnit
            self.proposalCount = proposalCount
            self.topClassRaw = topClassRaw
            self.topScore = topScore
            self.threw = threw
            self.prefillFired = prefillFired
            self.userCorrected = userCorrected
            self.fieldChanged = fieldChanged
        }
    }

    // MARK: - API

    /// Insert a telemetry row. Returns immediately when the feature
    /// flag is off or when no Supabase auth session exists. Errors
    /// are logged and swallowed so a failed upload never bubbles
    /// into user-visible surfaces.
    public func logInference(_ observation: Observation) async {
        let enabled = await MainActor.run { FeatureFlags.isMLTelemetryEnabled }
        guard enabled else { return }

        let userId: UUID
        do {
            userId = try await supabase.auth.session.user.id
        } catch {
            log.info("upload skipped: no session")
            return
        }

        let row = Row(userId: userId, observation: observation)
        do {
            try await supabase
                .from("ml_inference_telemetry")
                .insert(row)
                .execute()
        } catch {
            log.info("upload failed (swallowed): \(String(describing: error), privacy: .public)")
        }
    }

    /// Test / diagnostic accessor: returns whether the flag-gated
    /// upload would fire right now. Lets tests assert the gate
    /// without triggering a real network call.
    public func isUploadEnabled() async -> Bool {
        await MainActor.run { FeatureFlags.isMLTelemetryEnabled }
    }

    // MARK: - Private

    /// Wire-level row. Private so callers can't instantiate it
    /// without a user id — they go through `Observation` + the
    /// service's session lookup.
    private struct Row: Codable, Sendable {
        let userId: UUID
        let modelName: String
        let surface: String
        let latencyMs: Double
        let computeUnit: String?
        let proposalCount: Int?
        let topClassRaw: String?
        let topScore: Float?
        let threw: Bool
        let prefillFired: Bool?
        let userCorrected: Bool?
        let fieldChanged: String?

        init(userId: UUID, observation: Observation) {
            self.userId = userId
            self.modelName = observation.modelName
            self.surface = observation.surface
            self.latencyMs = observation.latencyMs
            self.computeUnit = observation.computeUnit
            self.proposalCount = observation.proposalCount
            self.topClassRaw = observation.topClassRaw
            self.topScore = observation.topScore
            self.threw = observation.threw
            self.prefillFired = observation.prefillFired
            self.userCorrected = observation.userCorrected
            self.fieldChanged = observation.fieldChanged
        }

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case modelName = "model_name"
            case surface
            case latencyMs = "latency_ms"
            case computeUnit = "compute_unit"
            case proposalCount = "proposal_count"
            case topClassRaw = "top_class_raw"
            case topScore = "top_score"
            case threw
            case prefillFired = "prefill_fired"
            case userCorrected = "user_corrected"
            case fieldChanged = "field_changed"
        }
    }
}
