import Foundation
import UIKit
import XCTest
@testable import WardrobeReDo

// MARK: - Extraction performance harness
//
// XCTClockMetric + XCTMemoryMetric live in XCTest, not Swift Testing, so
// this file uses `XCTestCase` while the IoU rig uses `@Test`. Both coexist
// in the same target.
//
// Targets (from the plan):
//   • Vision path — p95 wall clock < 0.8 s, peak memory < 120 MB
//   • SAM2 path   — p95 wall clock < 1.5 s warm, peak memory < 220 MB
//
// We don't hard-assert those numbers here. Xcode's metric report flags
// regressions at check-in against the device's own baseline; that's the
// signal we care about. What we DO assert: the rig runs at all, doesn't
// hang, and exercises both chaining paths. On the simulator every
// `measure` block short-circuits because Vision can't run without the
// Neural Engine.

final class ExtractionPerformanceTests: XCTestCase {
    func testVisionPath_perfBaseline() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision foreground requires a Neural Engine — device-only metric.")
        #else
        let fixture = try loadFirstFixtureImage(preferScenario: "clean_bg")
        let service = ClothingExtractionService()

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expect = expectation(description: "vision extraction")
            Task { @MainActor in
                _ = await service.extract(fixture)
                expect.fulfill()
            }
            wait(for: [expect], timeout: 5.0)
        }
        #endif
    }

    func testSAM2AutoPath_perfBaseline() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("SAM2 requires Core ML Neural Engine inference — device-only metric.")
        #else
        // Use an on-person fixture when available — that's the scenario the
        // auto-SAM2 fallback is actually rescuing.
        let fixture = try loadFirstFixtureImage(preferScenario: "on_person")
        let service = ClothingExtractionService()

        // Warm the model once so we're measuring steady-state latency, not
        // the cold-start model load (the production pre-warm on
        // AddItemView covers that case separately).
        let warmup = expectation(description: "warmup")
        Task { @MainActor in
            await service.prewarm()
            warmup.fulfill()
        }
        wait(for: [warmup], timeout: 10.0)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expect = expectation(description: "sam2 extraction")
            Task { @MainActor in
                _ = await service.extract(fixture)
                expect.fulfill()
            }
            wait(for: [expect], timeout: 10.0)
        }
        #endif
    }

    // MARK: - Helpers

    private func loadFirstFixtureImage(preferScenario scenario: String) throws -> UIImage {
        guard let manifest = FixtureLoader.loadManifest(), !manifest.fixtures.isEmpty else {
            throw XCTSkip("No fixtures in manifest — see Fixtures/Extraction/capture-brief.md")
        }
        let preferred = manifest.fixtures.first(where: { $0.scenario == scenario })
        let entry = preferred ?? manifest.fixtures[0]
        guard let image = FixtureLoader.loadImage(named: entry.image) else {
            throw XCTSkip("Fixture image missing: \(entry.image)")
        }
        return image
    }
}
