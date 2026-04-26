import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Unit tests for `MultiGarmentProposalService.compositeMaskedItem`.
///
/// Two paths to verify:
///   1. Mask provided → composite produces transparent background outside
///      the mask + opaque pixels inside. The wardrobe grid + Match tab +
///      Outfit cards all rely on this behavior to avoid the source-photo
///      backdrop bug.
///   2. Mask nil → fall back to plain rect crop (back-compat with the
///      legacy `cropped()` behavior so any nil-mask caller still gets a
///      usable image).
///
/// Tests use synthetic images / pixel buffers so they run without any
/// model bundled — same convention as `MultiGarmentProposalServiceTests`.
@Suite("MultiGarmentProposalService.masking") struct MultiGarmentProposalServiceMaskingTests {

    // MARK: - Composite path

    @Test func compositeMaskedItemProducesTransparentBgWhenMaskProvided() throws {
        // Build a 100×100 solid-red source image.
        let size = CGSize(width: 100, height: 100)
        let source = makeSolidImage(size: size, color: .red)

        // Build a 100×100 single-channel float mask: alpha=1 inside a
        // 40-px-radius circle centered at (50, 50), alpha=0 elsewhere.
        let mask = try #require(makeCircularFloatMask(width: 100, height: 100, radius: 40))

        // bbox covers the full image — easier to reason about pixel
        // positions in the output.
        let bbox = CGRect(x: 0, y: 0, width: 1, height: 1)

        let composited = try #require(MultiGarmentProposalService.compositeMaskedItem(
            sourceImage: source,
            mask: mask,
            bbox: bbox
        ))

        // PNG export must carry alpha. Round-trip through PNG so we
        // verify what actually gets written to Storage.
        let pngData = try #require(composited.pngData())
        let roundTripped = try #require(UIImage(data: pngData))
        let cg = try #require(roundTripped.cgImage)

        // Inside the circle (center ~ 50,50): alpha should be ~255 (mask).
        // The MaskCleaner pipeline (threshold + erode + blur) may shrink
        // the mask by 1 pixel — sample well inside the circle (center)
        // to avoid boundary artefacts.
        let centerAlpha = try #require(samplePixelAlpha(cg, x: 50, y: 50))
        #expect(centerAlpha > 200,
                "Pixel inside mask should be ~opaque, got alpha=\(centerAlpha)")

        // Outside the circle (corner): alpha should be ~0 (transparent).
        let cornerAlpha = try #require(samplePixelAlpha(cg, x: 5, y: 5))
        #expect(cornerAlpha < 30,
                "Pixel outside mask should be ~transparent, got alpha=\(cornerAlpha)")
    }

    @Test func compositeMaskedItemFallsBackToRectCropWhenMaskNil() throws {
        // Build a solid-red source and run the composite with mask: nil.
        // The output should be a plain rectangular crop of the bbox
        // region — same behavior as the legacy `cropped()` path.
        let size = CGSize(width: 100, height: 100)
        let source = makeSolidImage(size: size, color: .red)

        // bbox covers the right half (x: 0.5..1.0, full height) → 50×100.
        let bbox = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let cropped = try #require(MultiGarmentProposalService.compositeMaskedItem(
            sourceImage: source,
            mask: nil,
            bbox: bbox
        ))

        let cg = try #require(cropped.cgImage)
        // Rect crop, no mask: dimensions must match the bbox region.
        #expect(cg.width == 50, "Expected width 50, got \(cg.width)")
        #expect(cg.height == 100, "Expected height 100, got \(cg.height)")

        // The cropped pixels are still solid red; PNG export should
        // either be opaque or carry full-alpha pixels (no transparency).
        let pngData = try #require(cropped.pngData())
        let roundTripped = try #require(UIImage(data: pngData))
        let rcg = try #require(roundTripped.cgImage)
        let centerAlpha = try #require(samplePixelAlpha(rcg, x: 25, y: 50))
        #expect(centerAlpha == 255,
                "Rect-crop fallback must preserve full alpha, got \(centerAlpha)")
    }

    // MARK: - Helpers

    /// Produce a solid-color UIImage at the requested size.
    private func makeSolidImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Build a single-channel 32-bit-float `CVPixelBuffer` whose values
    /// are 1.0 inside a circle and 0.0 outside. Mirrors the buffer shape
    /// Vision and RFDETR-Seg emit (`kCVPixelFormatType_OneComponent32Float`)
    /// so we exercise the same code path as production.
    private func makeCircularFloatMask(width: Int, height: Int, radius: CGFloat) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent32Float,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let floats = base.assumingMemoryBound(to: Float32.self)

        let cx = CGFloat(width) / 2.0
        let cy = CGFloat(height) / 2.0
        let r2 = radius * radius

        for y in 0..<height {
            for x in 0..<width {
                let dx = CGFloat(x) - cx
                let dy = CGFloat(y) - cy
                let inside = (dx * dx + dy * dy) <= r2
                floats[y * floatsPerRow + x] = inside ? 1.0 : 0.0
            }
        }
        return pb
    }

    /// Sample the alpha channel of a single pixel at `(x, y)` from a
    /// `CGImage`. Renders the pixel into an alpha-only context so we
    /// don't have to track the source's color space / premultiplication.
    private func samplePixelAlpha(_ cg: CGImage, x: Int, y: Int) -> UInt8? {
        let w = cg.width
        let h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard x >= 0, x < w, y >= 0, y < h else { return nil }
        return pixels[y * w + x]
    }
}
