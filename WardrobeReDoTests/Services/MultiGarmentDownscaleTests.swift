import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Coverage for `MultiGarmentProposalService.downscaledForCutouts(_:)`.
/// The function trades inference fidelity (none — model preprocesses to
/// 1024×1024 anyway) for a 5-10× reduction in proposal-cutout RAM,
/// which is the watchdog-termination root cause we hit on TestFlight
/// 1.0.0 (1) — see Sentry WARDROBE-REDO-IOS-1.
///
/// Three things to assert:
///   1. Already-small images are returned unchanged (no allocation,
///      no aliasing — same instance).
///   2. Oversized images are downscaled so the longest side equals
///      `workingImageMaxDimension`, with the aspect ratio preserved.
///   3. Render scale is 1, so the returned bitmap memory is exactly
///      `width × height × 4` bytes — the device's native scale would
///      multiply this by `UIScreen.main.scale²` and undo the savings.
@Suite("MultiGarmentProposalService.downscaledForCutouts") struct MultiGarmentDownscaleTests {

    @Test func smallImagePassesThroughUnchanged() {
        let small = makeImage(size: CGSize(width: 800, height: 600))
        let result = MultiGarmentProposalService.downscaledForCutouts(small)
        // Small-enough → identity. We compare object identity to prove
        // no copy was made.
        #expect(result === small)
    }

    @Test func borderlineImageAtCapPassesThroughUnchanged() {
        let cap = MultiGarmentProposalService.workingImageMaxDimension
        let borderline = makeImage(size: CGSize(width: cap, height: cap * 0.5))
        let result = MultiGarmentProposalService.downscaledForCutouts(borderline)
        #expect(result === borderline)
    }

    @Test func oversizedLandscapeIsScaledToMaxDim() {
        let cap = MultiGarmentProposalService.workingImageMaxDimension
        let big = makeImage(size: CGSize(width: 4032, height: 3024))
        let result = MultiGarmentProposalService.downscaledForCutouts(big)

        // Longest side hits the cap.
        #expect(result.size.width == cap)
        // Aspect ratio preserved (within a 1px tolerance for floor()).
        let expectedHeight = floor(3024 * (cap / 4032))
        #expect(abs(result.size.height - expectedHeight) <= 1)
    }

    @Test func oversizedPortraitIsScaledToMaxDim() {
        let cap = MultiGarmentProposalService.workingImageMaxDimension
        let big = makeImage(size: CGSize(width: 3024, height: 4032))
        let result = MultiGarmentProposalService.downscaledForCutouts(big)

        #expect(result.size.height == cap)
        let expectedWidth = floor(3024 * (cap / 4032))
        #expect(abs(result.size.width - expectedWidth) <= 1)
    }

    @Test func renderScaleIsOneToBoundBitmapMemory() {
        let big = makeImage(size: CGSize(width: 4032, height: 3024))
        let result = MultiGarmentProposalService.downscaledForCutouts(big)

        // Forcing scale=1 keeps bitmap RAM at width*height*4 bytes.
        // The device's native scale (e.g. 3.0 on @3x phones) would
        // multiply this by 9× and undo the OOM-fix savings.
        #expect(result.scale == 1.0)
    }

    // MARK: - Helpers

    private func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
