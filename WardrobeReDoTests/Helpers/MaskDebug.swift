import CoreVideo
import Foundation

/// Small diagnostic helper used in failure messages for
/// `SegmentationIoUTests`. Reports mask coverage (fraction of pixels
/// whose value exceeds 127) so a zero-IoU failure can be separated
/// from "mask too small" vs "mask in the wrong place".
enum MaskDebug {
    static func coverage(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var on = 0
        for y in 0..<height {
            for x in 0..<width where src[y * bytesPerRow + x] > 127 {
                on += 1
            }
        }
        let total = width * height
        return total > 0 ? Double(on) / Double(total) : 0
    }
}
