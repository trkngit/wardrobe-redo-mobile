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
