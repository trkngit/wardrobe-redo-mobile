import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - AlphaTrimmer (build 31)
//
// Verifies the alpha-bounds detection + crop contract that
// ItemThumbnailView depends on for consistent grid fill. The trim
// helper is purely a CGImage transformation, so tests render
// synthetic images with known transparent padding and assert the
// trimmed result's dimensions.

@MainActor
@Suite("AlphaTrimmerTests")
struct AlphaTrimmerTests {

    /// Pin scale=1 so pixel counts equal point counts and the
    /// assertions don't depend on which device the test runs on.
    /// Without this, `UIGraphicsImageRenderer` uses the device
    /// scale (3× on iPhone, 2× on simulator) and a 200×200 point
    /// canvas becomes a 600×600 pixel bitmap.
    private static func makeRendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return format
    }

    /// Render a 200×200 image with a fully-opaque 100×100 square
    /// centered. The trim should crop down to ~104×104 (the
    /// inner square + 2px breathing margin per side).
    @Test func trimsTransparentPaddingToInnerSquare() {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 200, height: 200),
            format: Self.makeRendererFormat()
        )
        let image = renderer.image { ctx in
            // Transparent everywhere except a 100×100 center square.
            UIColor.clear.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        }

        let trimmed = AlphaTrimmer.trimmed(image)
        #expect(trimmed != nil)
        let trimmedCG = trimmed?.cgImage
        #expect(trimmedCG != nil)
        // 100 px content + 2 px margin on each side = 104 px.
        // Allow ±2 px for rendering rounding.
        let width = trimmedCG?.width ?? 0
        let height = trimmedCG?.height ?? 0
        #expect(abs(width - 104) <= 2)
        #expect(abs(height - 104) <= 2)
    }

    /// A fully-opaque image with no transparent padding to trim.
    /// The implementation's "skip if already tight" branch returns
    /// nil — caller is expected to keep the original image rather
    /// than re-render an identical one.
    @Test func returnsNilForFullyOpaqueImage() {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 100, height: 100),
            format: Self.makeRendererFormat()
        )
        let image = renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }

        let trimmed = AlphaTrimmer.trimmed(image)
        #expect(trimmed == nil)
    }

    /// A fully-transparent image has no non-transparent pixels at
    /// all — returns nil so the caller renders the placeholder.
    @Test func returnsNilForFullyTransparentImage() {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 100, height: 100),
            format: Self.makeRendererFormat()
        )
        let image = renderer.image { _ in
            // Draw nothing — bitmap remains all-transparent.
        }
        let trimmed = AlphaTrimmer.trimmed(image)
        #expect(trimmed == nil)
    }

    /// Off-center content (a 60×60 square in the top-left 80×80
    /// region of a 200×200 image) should still be trimmed correctly
    /// — the helper doesn't assume the content is centered.
    @Test func trimsOffCenterContent() {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 200, height: 200),
            format: Self.makeRendererFormat()
        )
        let image = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }

        let trimmed = AlphaTrimmer.trimmed(image)
        #expect(trimmed != nil)
        let trimmedCG = trimmed?.cgImage
        // 60 px content + 2 px margin on each side = 64 px.
        let width = trimmedCG?.width ?? 0
        #expect(abs(width - 64) <= 2)
    }
}
