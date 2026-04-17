import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - BackgroundQualityClassifier Tests
//
// These exercise the pure threshold logic only — there's no live
// CMSampleBuffer in the test target, so frame sampling itself is
// exercised manually on device (see the Phase 2 verification plan).
// The `BackgroundQualityClassifier.classify(...)` function is the
// contract the HUD consumer depends on; nail it down here.

@Test func classifierReportsGoodForCleanMidGreyBackground() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.55,
        maxStddev: 0.05,
        maxEdgeDensity: 0.02
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .good)
}

@Test func classifierReportsTooDarkBelowDarkCeiling() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.10,
        maxStddev: 0.05,
        maxEdgeDensity: 0.01
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooDark)
}

@Test func classifierReportsTooBrightAboveBrightFloor() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.95,
        maxStddev: 0.02,
        maxEdgeDensity: 0.01
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooBright)
}

@Test func classifierReportsTooTexturedWhenStddevExceedsCeiling() {
    // Mid-luminance, reasonable edge count, but high variance → textured.
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.5,
        maxStddev: 0.30,
        maxEdgeDensity: 0.05
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooTextured)
}

@Test func classifierReportsTooBusyWhenEdgeDensityExceedsCeiling() {
    // Low variance (not textured) but lots of sharp edges → busy.
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.5,
        maxStddev: 0.08,
        maxEdgeDensity: 0.40
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooBusy)
}

// 2026-04-18: the default edge-density ceiling was raised from 0.12
// → 0.22. Typical furnished rooms pack ~0.15–0.20 edge density into at
// least one corner patch; that level used to trip `.tooBusy` and disable
// the shutter, which is what the user hit when they couldn't take a
// photo of a person in a suit. Lock the relaxation in so a future
// threshold tweak can't silently re-introduce the block.
@Test func classifierTreatsIndoorEdgeDensityAsGoodAfterRelaxation() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.5,
        maxStddev: 0.08,
        maxEdgeDensity: 0.18  // used to be .tooBusy; now .good
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .good)
}

// Just above the new ceiling should still trip `.tooBusy` — we loosened,
// we didn't disable the check entirely.
@Test func classifierStillFlagsGenuineBusyAboveNewCeiling() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.5,
        maxStddev: 0.08,
        maxEdgeDensity: 0.25
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooBusy)
}

// Order of checks matters — darkness wins before texture/edges.
@Test func classifierDarknessWinsOverTexture() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.05,
        maxStddev: 0.9,       // would be textured
        maxEdgeDensity: 0.9   // would be busy
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooDark)
}

// Brightness also wins before texture/edges — blown-out frames can't
// be classified for structure.
@Test func classifierBrightnessWinsOverBusy() {
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.95,
        maxStddev: 0.05,
        maxEdgeDensity: 0.9
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics) == .tooBright)
}

// Custom threshold lets callers tune per-lighting. Good escape hatch.
@Test func classifierHonorsCustomThresholds() {
    // With default thresholds this is good. With a strict threshold it
    // should tip over into tooTextured.
    let metrics = BackgroundQualityMetrics(
        meanLuminance: 0.55,
        maxStddev: 0.08,
        maxEdgeDensity: 0.02
    )
    let strict = BackgroundQualityThresholds(
        darkCeiling: 0.25,
        brightFloor: 0.85,
        stddevCeiling: 0.05,
        edgeDensityCeiling: 0.12
    )
    #expect(BackgroundQualityClassifier.classify(metrics: metrics, thresholds: strict) == .tooTextured)
}

// MARK: - Coaching / semantic color metadata

@Test func qualityUnknownShowsNeutralColor() {
    #expect(BackgroundQuality.unknown.semanticColor == .neutral)
}

@Test func qualityGoodShowsPositiveColor() {
    #expect(BackgroundQuality.good.semanticColor == .positive)
}

@Test func qualityAllNonGoodNonUnknownShowWarningColor() {
    let warnings: [BackgroundQuality] = [.tooDark, .tooBright, .tooBusy, .tooTextured]
    for quality in warnings {
        #expect(quality.semanticColor == .warning)
    }
}

@Test func qualityCoachingTextIsNeverEmpty() {
    for quality in [BackgroundQuality.unknown, .good, .tooDark, .tooBright, .tooBusy, .tooTextured] {
        #expect(!quality.coachingText.isEmpty)
    }
}
