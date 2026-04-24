import Foundation
import Testing
@testable import WardrobeReDo

/// Unit tests for the `MLDiagnosticsStore` ring buffer + status
/// transitions. Runs on `MainActor` because the store is MainActor-
/// isolated to keep its Observation-backed reads UI-thread safe.
///
/// `@Suite(.serialized)` because all tests share the singleton
/// `MLDiagnosticsStore.shared` — Swift Testing's default parallel
/// execution within a suite would have tests step on each other's
/// records / smoke-test state. Cross-suite isolation is enforced via
/// `MLDiagnosticsTestIsolation`; without it `MultiGarmentSmokeTestTests`
/// could stomp our `resetAll()` mid-assertion (both suites mutate the
/// same singleton and Swift Testing runs suites in parallel).
@MainActor
@Suite(.serialized)
struct MLDiagnosticsStoreTests {

    // MARK: - Record insertion

    @Test func recordInsertsMostRecentFirst() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()

        MLDiagnosticsStore.shared.record(
            latencyMs: 100,
            proposals: [MaskProposalFixture.make(detectionScore: 0.9, modelClassRaw: "shirt_blouse")],
            modelName: "TestModel"
        )
        MLDiagnosticsStore.shared.record(
            latencyMs: 200,
            proposals: [MaskProposalFixture.make(detectionScore: 0.8, modelClassRaw: "skirt")],
            modelName: "TestModel"
        )

        #expect(MLDiagnosticsStore.shared.records.count == 2)
        #expect(MLDiagnosticsStore.shared.records.first?.latencyMs == 200)
        #expect(MLDiagnosticsStore.shared.records.last?.latencyMs == 100)
    }

    @Test func recordTopPredictionsCappedAtThree() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()

        let proposals = (0 ..< 5).map { i in
            MaskProposalFixture.make(
                detectionScore: Float(1.0 - Double(i) * 0.1),
                modelClassRaw: "class_\(i)"
            )
        }

        MLDiagnosticsStore.shared.record(
            latencyMs: 150,
            proposals: proposals,
            modelName: "TestModel"
        )

        let record = MLDiagnosticsStore.shared.records.first
        #expect(record?.topPredictions.count == 3,
                "Only top 3 proposals should be stored for the diagnostic row")
        #expect(record?.topPredictions[0].rawClass == "class_0")
        #expect(record?.topPredictions[2].rawClass == "class_2")
        #expect(record?.proposalCount == 5,
                "Proposal count reflects the full detection set, not the capped top-3")
    }

    @Test func recordFailureTagsRecordAsThrew() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        MLDiagnosticsStore.shared.recordFailure(latencyMs: 50, modelName: "TestModel")

        let record = MLDiagnosticsStore.shared.records.first
        #expect(record?.threw == true)
        #expect(record?.proposalCount == 0)
        #expect(record?.topPredictions.isEmpty == true)
    }

    // MARK: - Ring-buffer capping

    @Test func ringBufferCapsAtMaxRecords() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()

        for i in 0 ..< (MLDiagnosticsStore.maxRecords + 5) {
            MLDiagnosticsStore.shared.record(
                latencyMs: Double(i),
                proposals: [],
                modelName: "TestModel"
            )
        }

        #expect(MLDiagnosticsStore.shared.records.count == MLDiagnosticsStore.maxRecords)
        // Ensure we kept the MOST RECENT entries, not the oldest
        #expect(MLDiagnosticsStore.shared.records.first?.latencyMs
                == Double(MLDiagnosticsStore.maxRecords + 4))
    }

    // MARK: - Smoke test status

    @Test func smokeTestStatusRoundTrips() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == .notRun)

        MLDiagnosticsStore.shared.setSmokeTestStatus(.running)
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == .running)

        MLDiagnosticsStore.shared.setSmokeTestStatus(.passed(latencyMs: 120))
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == .passed(latencyMs: 120))

        MLDiagnosticsStore.shared.setSmokeTestStatus(.failed(reason: "bad"))
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == .failed(reason: "bad"))

        MLDiagnosticsStore.shared.setSmokeTestStatus(.skipped(reason: "no model"))
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == .skipped(reason: "no model"))
    }

    // MARK: - Derived helpers

    @Test func inferredComputeUnitReflectsLatestLatency() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()

        // Latest = 100 ms → ANE lane
        MLDiagnosticsStore.shared.record(latencyMs: 1000, proposals: [], modelName: "m")
        MLDiagnosticsStore.shared.record(latencyMs: 100, proposals: [], modelName: "m")
        #expect(MLDiagnosticsStore.shared.inferredComputeUnit == "ANE (likely)")

        // Insert a 500 ms record on top → GPU band
        MLDiagnosticsStore.shared.record(latencyMs: 500, proposals: [], modelName: "m")
        #expect(MLDiagnosticsStore.shared.inferredComputeUnit == "GPU (likely)")

        // Insert a 1200 ms record on top → CPU band
        MLDiagnosticsStore.shared.record(latencyMs: 1200, proposals: [], modelName: "m")
        #expect(MLDiagnosticsStore.shared.inferredComputeUnit == "CPU (likely)")
    }

    @Test func medianLatencyIgnoresThrows() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()

        MLDiagnosticsStore.shared.record(latencyMs: 100, proposals: [], modelName: "m")
        MLDiagnosticsStore.shared.record(latencyMs: 300, proposals: [], modelName: "m")
        MLDiagnosticsStore.shared.recordFailure(latencyMs: 9999, modelName: "m")
        MLDiagnosticsStore.shared.record(latencyMs: 200, proposals: [], modelName: "m")

        // Successful: [100, 200, 300] → median 200; thrown 9999 excluded
        #expect(MLDiagnosticsStore.shared.medianLatencyMs == 200)
    }

    @Test func medianLatencyReturnsNilWhenNoSuccesses() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.resetAll()
        #expect(MLDiagnosticsStore.shared.medianLatencyMs == nil)

        MLDiagnosticsStore.shared.recordFailure(latencyMs: 500, modelName: "m")
        #expect(MLDiagnosticsStore.shared.medianLatencyMs == nil,
                "Median ignores thrown records")
    }

    // MARK: - Reset

    @Test func resetAllClearsState() async {
        await MLDiagnosticsTestIsolation.shared.acquire()
        defer { Task { await MLDiagnosticsTestIsolation.shared.release() } }

        MLDiagnosticsStore.shared.record(latencyMs: 100, proposals: [], modelName: "m")
        MLDiagnosticsStore.shared.setSmokeTestStatus(.passed(latencyMs: 50))

        MLDiagnosticsStore.shared.resetAll()
        #expect(MLDiagnosticsStore.shared.records.isEmpty)
        #expect(MLDiagnosticsStore.shared.smokeTestStatus == .notRun)
    }
}
