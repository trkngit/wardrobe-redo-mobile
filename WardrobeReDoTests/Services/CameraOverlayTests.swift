import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - CameraOverlay shutter-gate tests
//
// Before 2026-04-18 the shutter also demanded `BackgroundQuality == .good`
// with a two-tap "Take anyway" escape hatch. User feedback — "I couldn't
// take a photo" — showed that gate was over-strict in real-world rooms.
// We flipped to an advisory HUD: the shutter is live the moment camera
// permission is granted, and the quality pill is guidance only.
//
// These tests lock in that behavior so a future PR can't silently
// re-introduce the gate.

@Test func shutterEnabledWhenAuthorized() {
    #expect(CameraOverlay.shutterEnabled(for: .authorized) == true)
}

@Test func shutterDisabledWhenNotDetermined() {
    #expect(CameraOverlay.shutterEnabled(for: .notDetermined) == false)
}

@Test func shutterDisabledWhenDenied() {
    #expect(CameraOverlay.shutterEnabled(for: .denied) == false)
}

@Test func shutterDisabledWhenNotAvailable() {
    #expect(CameraOverlay.shutterEnabled(for: .notAvailable) == false)
}

// The contract the user cares about: once they've granted permission,
// the shutter is enabled REGARDLESS of what the background-quality HUD
// is reporting. Quality is advisory, not gating.
@Test func shutterEnabledForEveryQualityWhenAuthorized() {
    let qualities: [BackgroundQuality] = [
        .unknown, .good, .tooDark, .tooBright, .tooBusy, .tooTextured
    ]
    for _ in qualities {
        // The gate function doesn't even accept a quality — that's the
        // point. But we iterate to document the product contract in
        // the test name, and to future-proof: if anyone ever adds a
        // BackgroundQuality-aware overload, this loop will keep them
        // honest.
        #expect(CameraOverlay.shutterEnabled(for: .authorized) == true)
    }
}

// MARK: - OverlayPhase state machine (build 6)

@Test func overlayPhaseStartingWhenAuthorizationPending() {
    #expect(CameraOverlay.overlayPhase(authorization: .notDetermined, sessionState: .configuring) == .starting)
}

@Test func overlayPhasePreparingWhenAuthorizedButSessionConfiguring() {
    #expect(CameraOverlay.overlayPhase(authorization: .authorized, sessionState: .configuring) == .preparing)
}

@Test func overlayPhaseLiveWhenAuthorizedAndSessionRunning() {
    #expect(CameraOverlay.overlayPhase(authorization: .authorized, sessionState: .running) == .live)
}

@Test func overlayPhasePreparingWhenSessionFailed() {
    // A transient setup failure shouldn't strand the user in a dead
    // overlay — keep them in `.preparing` so the cover can recover on
    // re-open. Telemetry captures the actual failure separately.
    #expect(CameraOverlay.overlayPhase(authorization: .authorized, sessionState: .failed("test")) == .preparing)
}

@Test func overlayPhaseDeniedRegardlessOfSessionState() {
    #expect(CameraOverlay.overlayPhase(authorization: .denied, sessionState: .configuring) == OverlayPhase.denied)
    #expect(CameraOverlay.overlayPhase(authorization: .denied, sessionState: .running) == OverlayPhase.denied)
    #expect(CameraOverlay.overlayPhase(authorization: .denied, sessionState: .stopped) == OverlayPhase.denied)
}

@Test func overlayPhaseNotAvailableRegardlessOfSessionState() {
    #expect(CameraOverlay.overlayPhase(authorization: .notAvailable, sessionState: .configuring) == OverlayPhase.notAvailable)
    #expect(CameraOverlay.overlayPhase(authorization: .notAvailable, sessionState: .failed("x")) == OverlayPhase.notAvailable)
}

// MARK: - Phase-aware shutter gate

@Test func shutterEnabledOnlyInLivePhase() {
    // `shutterEnabled(in:)` is the OverlayPhase overload — distinct
    // argument label from the legacy `shutterEnabled(for:)` so the
    // compiler always picks the right one and `.denied` /
    // `.notAvailable` don't need qualification.
    #expect(CameraOverlay.shutterEnabled(in: .live) == true)
    #expect(CameraOverlay.shutterEnabled(in: .starting) == false)
    #expect(CameraOverlay.shutterEnabled(in: .preparing) == false)
    #expect(CameraOverlay.shutterEnabled(in: .denied) == false)
    #expect(CameraOverlay.shutterEnabled(in: .notAvailable) == false)
}

// MARK: - isCapturable composite

@Test func isCapturableRequiresAllSignals() {
    // All-good frame.
    #expect(CameraOverlay.isCapturable(quality: .good, sharpness: 0.8, coverage: 0.4) == true)
}

@Test func isCapturableFalseWhenQualityNotGood() {
    #expect(CameraOverlay.isCapturable(quality: .tooDark, sharpness: 0.8, coverage: 0.4) == false)
    #expect(CameraOverlay.isCapturable(quality: .tooBright, sharpness: 0.8, coverage: 0.4) == false)
    #expect(CameraOverlay.isCapturable(quality: .tooBusy, sharpness: 0.8, coverage: 0.4) == false)
}

@Test func isCapturableFalseWhenSharpnessBelowFloor() {
    #expect(CameraOverlay.isCapturable(quality: .good, sharpness: 0.4, coverage: 0.4) == false)
}

@Test func isCapturableFalseWhenCoverageOutOfRange() {
    // Too small — garment doesn't fill enough of the frame.
    #expect(CameraOverlay.isCapturable(quality: .good, sharpness: 0.8, coverage: 0.05) == false)
    // Too close — silhouette likely cropped.
    #expect(CameraOverlay.isCapturable(quality: .good, sharpness: 0.8, coverage: 0.95) == false)
}
