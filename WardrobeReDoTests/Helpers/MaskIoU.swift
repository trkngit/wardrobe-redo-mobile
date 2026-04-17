import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

// MARK: - MaskIoU
//
// Computes intersection-over-union between two alpha masks. The extractor
// emits `CVPixelBuffer` in `kCVPixelFormatType_OneComponent8` (from both
// Vision and SAM2 paths). Ground-truth PNGs load at their own resolution, so
// the helper rescales the ground truth to match the predicted mask before
// scoring.
//
// This intentionally runs on CPU in pure Swift — it's test-only, the masks
// are small (≤ 1024² in practice), and going through a Core Image pipeline
// adds a bunch of dependencies that break simulator runs. Plain loops are
// both faster and easier to debug when a fixture IoU drops.

enum MaskIoU {
    /// IoU ∈ [0, 1]. Returns 0 when either buffer is empty or shapes can't
    /// be reconciled.
    static func score(prediction: CVPixelBuffer, groundTruth: CVPixelBuffer) -> Double {
        let predWidth = CVPixelBufferGetWidth(prediction)
        let predHeight = CVPixelBufferGetHeight(prediction)
        guard predWidth > 0, predHeight > 0 else { return 0 }

        // Resize ground-truth to match prediction resolution (nearest
        // neighbour is fine for a binary mask and keeps the rig cheap).
        guard let gtResized = resize(groundTruth, toWidth: predWidth, height: predHeight) else {
            return 0
        }

        guard let predPixels = readGrayscale(prediction),
              let gtPixels = readGrayscale(gtResized) else {
            return 0
        }

        precondition(predPixels.count == gtPixels.count)

        var intersection = 0
        var union = 0
        for i in 0..<predPixels.count {
            let predOn = predPixels[i] > 127
            let gtOn = gtPixels[i] > 127
            if predOn && gtOn { intersection += 1 }
            if predOn || gtOn { union += 1 }
        }
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    // MARK: - Private

    private static func readGrayscale(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)

        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = src[y * bytesPerRow + x]
            }
        }
        return out
    }

    private static func resize(_ buffer: CVPixelBuffer, toWidth width: Int, height: Int) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(buffer)
        let srcHeight = CVPixelBufferGetHeight(buffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        if srcWidth == width && srcHeight == height {
            return buffer
        }

        guard let srcPixels = readGrayscale(buffer) else { return nil }

        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &output
        )
        guard status == kCVReturnSuccess, let out = output else { return nil }

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(out)
        guard let base = CVPixelBufferGetBaseAddress(out) else { return nil }
        let dst = base.assumingMemoryBound(to: UInt8.self)

        let scaleX = Double(srcWidth) / Double(width)
        let scaleY = Double(srcHeight) / Double(height)
        for y in 0..<height {
            let srcY = min(srcHeight - 1, Int(Double(y) * scaleY))
            for x in 0..<width {
                let srcX = min(srcWidth - 1, Int(Double(x) * scaleX))
                dst[y * dstBytesPerRow + x] = srcPixels[srcY * srcWidth + srcX]
            }
        }
        return out
    }
}
