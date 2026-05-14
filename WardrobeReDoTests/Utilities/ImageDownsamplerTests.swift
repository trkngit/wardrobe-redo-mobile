import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

// MARK: - ImageDownsampler (build 29)
//
// Verifies the Data-input path that the library + camera flows
// route through. The UIImage-input path is exercised indirectly
// by the existing AddItemViewModel suite (Build 26 onwards), so
// we focus here on the new CGImageSource thumbnail variant.

@MainActor
@Suite("ImageDownsamplerTests")
struct ImageDownsamplerTests {

    /// Render a solid-color UIImage at the requested pixel size and
    /// encode it to PNG Data — the closest local approximation to a
    /// PhotosPicker payload without a real picker session.
    private func makePNGData(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(
            size: size,
            format: {
                let f = UIGraphicsImageRendererFormat()
                f.scale = 1.0
                return f
            }()
        )
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }

    @Test func downsamplesLargeSourceToCap() {
        // A 4096×3072 input (≈12 MP, mid-iPhone) should come back
        // with its long edge clamped to the 2048 px default cap.
        let data = makePNGData(width: 4096, height: 3072)
        let downsampled = ImageDownsampler.downsampled(from: data)
        #expect(downsampled != nil)
        // `cgImage` width is in pixels — exactly what we asked
        // CGImageSourceCreateThumbnailAtIndex to cap.
        let pixelWidth = downsampled?.cgImage?.width ?? 0
        #expect(pixelWidth <= 2048)
        #expect(pixelWidth >= 1024)
    }

    @Test func leavesSmallSourceUntouched() {
        // A 800×600 input is already below the cap; the thumbnail
        // path may still re-emit it but the result stays small —
        // the contract is "long edge <= cap", not "preserves
        // identity".
        let data = makePNGData(width: 800, height: 600)
        let downsampled = ImageDownsampler.downsampled(from: data)
        #expect(downsampled != nil)
        let pixelWidth = downsampled?.cgImage?.width ?? 0
        #expect(pixelWidth <= 2048)
    }

    @Test func returnsNilForInvalidData() {
        // Garbage bytes — not a recognized image format. Should
        // return nil so the caller can surface a "couldn't load"
        // message rather than crashing.
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        let downsampled = ImageDownsampler.downsampled(from: garbage)
        #expect(downsampled == nil)
    }

    @Test func respectsCustomMaxDimension() {
        // Caller can clamp tighter than the default 2048 px (e.g.
        // for a thumbnail strip). Confirms the parameter actually
        // flows through to CGImageSource.
        let data = makePNGData(width: 4000, height: 4000)
        let downsampled = ImageDownsampler.downsampled(from: data, maxDimension: 512)
        #expect(downsampled != nil)
        let pixelWidth = downsampled?.cgImage?.width ?? 0
        #expect(pixelWidth <= 512)
    }
}
