import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

/// GPU-accelerated sharpness metric for the live camera preview.
///
/// Computes the variance of the Laplacian-filtered luma channel — the
/// well-known PyImageSearch / Pech-Pacheco blur metric — over a center
/// 256×256 patch of the frame. High variance ⇒ many sharp edges ⇒
/// in-focus. Low variance ⇒ smooth, blurry image.
///
/// The pipeline runs entirely on the GPU via Metal Performance
/// Shaders: `MPSImageLaplacian` for the second-derivative, then
/// `MPSImageStatisticsMeanAndVariance` for the reduction. Per-frame
/// cost on A15+ is ~1 ms; combined with the monitor's 4 Hz cap, total
/// CPU overhead stays well under 1 %.
///
/// We piggy-back on the Y plane already produced by the AVCapture
/// config (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`), so no
/// color-space conversion is needed.
///
/// Tuning thresholds derive from the standard PyImageSearch baseline
/// of 100 for generic photos, raised to 150 for the "sharp" floor
/// because flat-lay clothing on a clean surface has lower mean
/// gradient density than typical photographs. The blur floor of 30
/// catches the genuinely-out-of-focus case where Laplacian responses
/// approach sensor noise.
enum SharpnessMetric {
    /// Side length of the center crop fed into the Laplacian pass.
    /// 256×256 is large enough to capture meaningful edge content and
    /// small enough to keep the MPS pipeline within sub-millisecond
    /// territory on iPhone-class GPUs.
    static let centerPatchSide: Int = 256

    /// Raw variance values at or above this floor map to `1.0` in the
    /// normalized [0,1] output. Derived from PyImageSearch's 100
    /// baseline + a flat-lay clothing margin.
    static let rawVarianceSharpFloor: Float = 150.0

    /// Raw variance values at or below this floor map to `0.0`.
    /// Anything below this is reliably blurry — the Laplacian
    /// response is near sensor noise.
    static let rawVarianceBlurFloor: Float = 30.0

    /// Computes a normalized sharpness score in [0,1] from the Y
    /// plane of a CVPixelBuffer. Returns `nil` when the GPU pipeline
    /// can't be initialized (rare; e.g. simulator without Metal) or
    /// when the input buffer is too small for the center patch.
    static func sharpness(from pixelBuffer: CVPixelBuffer) -> Float? {
        guard let raw = rawLaplacianVariance(from: pixelBuffer) else { return nil }
        return normalize(rawVariance: raw)
    }

    /// Maps a raw Laplacian variance to [0,1]. Exposed for unit tests
    /// so we can verify the normalization curve without standing up a
    /// full pipeline.
    static func normalize(rawVariance: Float) -> Float {
        let range = rawVarianceSharpFloor - rawVarianceBlurFloor
        let clamped = max(0, rawVariance - rawVarianceBlurFloor)
        return min(1.0, clamped / range)
    }

    /// Returns the raw Laplacian variance (unnormalized) for the
    /// center patch of the buffer's Y plane. Exposed so tests can
    /// pin the floor / ceiling without depending on the normalization
    /// curve.
    static func rawLaplacianVariance(from pixelBuffer: CVPixelBuffer) -> Float? {
        guard let context = Self.context else { return nil }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width >= centerPatchSide, height >= centerPatchSide else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Carve out the center patch into a contiguous staging buffer.
        // We copy because MPS textures expect tightly-packed bytes;
        // the CVPixelBuffer's per-row stride may include padding.
        let originX = (width - centerPatchSide) / 2
        let originY = (height - centerPatchSide) / 2
        var staging = [UInt8](repeating: 0, count: centerPatchSide * centerPatchSide)
        let srcBase = base.assumingMemoryBound(to: UInt8.self)
        staging.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<centerPatchSide {
                let src = srcBase.advanced(by: (originY + row) * bytesPerRow + originX)
                memcpy(dstBase.advanced(by: row * centerPatchSide), src, centerPatchSide)
            }
        }

        return context.runVariance(over: staging)
    }

    // MARK: - Metal context

    /// One-time MPS pipeline. Allocated lazily on first use; nil on
    /// platforms without Metal (e.g. older simulators) — callers
    /// should treat that as "no sharpness signal" and fall through
    /// to coarser quality signals.
    ///
    /// `MetalContext` is `@unchecked Sendable` (see class declaration)
    /// — Metal types are thread-safe by design when each call produces
    /// its own command buffer + texture, which the `runVariance`
    /// path does. The shared `let` is immutable after init, so
    /// concurrent reads of the cached context are safe.
    private static let context: MetalContext? = MetalContext.make()

    final class MetalContext: @unchecked Sendable {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let inputDescriptor: MTLTextureDescriptor
        let lapDescriptor: MTLTextureDescriptor
        let stats: MPSImageStatisticsMeanAndVariance
        let laplacian: MPSImageLaplacian

        static func make() -> MetalContext? {
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            guard let queue = device.makeCommandQueue() else { return nil }
            let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: centerPatchSide,
                height: centerPatchSide,
                mipmapped: false
            )
            inputDesc.usage = [.shaderRead, .shaderWrite]
            inputDesc.storageMode = .shared

            let lapDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float,
                width: centerPatchSide,
                height: centerPatchSide,
                mipmapped: false
            )
            lapDesc.usage = [.shaderRead, .shaderWrite]
            lapDesc.storageMode = .shared

            return MetalContext(
                device: device,
                commandQueue: queue,
                inputDescriptor: inputDesc,
                lapDescriptor: lapDesc,
                stats: MPSImageStatisticsMeanAndVariance(device: device),
                laplacian: MPSImageLaplacian(device: device)
            )
        }

        init(
            device: MTLDevice,
            commandQueue: MTLCommandQueue,
            inputDescriptor: MTLTextureDescriptor,
            lapDescriptor: MTLTextureDescriptor,
            stats: MPSImageStatisticsMeanAndVariance,
            laplacian: MPSImageLaplacian
        ) {
            self.device = device
            self.commandQueue = commandQueue
            self.inputDescriptor = inputDescriptor
            self.lapDescriptor = lapDescriptor
            self.stats = stats
            self.laplacian = laplacian
        }

        /// Runs the Laplacian → variance pipeline over the staged
        /// `centerPatchSide × centerPatchSide` byte array. Returns the
        /// raw variance in [0, ~10000] roughly (in r16Float units
        /// after Laplacian; we read back a 1×2 r32Float result with
        /// (mean, variance) in the .r and .g channels).
        func runVariance(over staging: [UInt8]) -> Float? {
            guard let inputTex = device.makeTexture(descriptor: inputDescriptor) else { return nil }
            guard let lapTex = device.makeTexture(descriptor: lapDescriptor) else { return nil }

            staging.withUnsafeBufferPointer { ptr in
                inputTex.replace(
                    region: MTLRegionMake2D(0, 0, centerPatchSide, centerPatchSide),
                    mipmapLevel: 0,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: centerPatchSide
                )
            }

            // MPSImageStatisticsMeanAndVariance produces a 1×2 r32Float
            // result texture per source: [0] = mean, [1] = variance.
            let resultDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: 2,
                height: 1,
                mipmapped: false
            )
            resultDesc.usage = [.shaderRead, .shaderWrite]
            resultDesc.storageMode = .shared
            guard let resultTex = device.makeTexture(descriptor: resultDesc) else { return nil }

            guard let buffer = commandQueue.makeCommandBuffer() else { return nil }
            laplacian.encode(commandBuffer: buffer, sourceTexture: inputTex, destinationTexture: lapTex)
            stats.encode(commandBuffer: buffer, sourceTexture: lapTex, destinationTexture: resultTex)
            buffer.commit()
            buffer.waitUntilCompleted()

            var pixels: [Float] = [0, 0]
            pixels.withUnsafeMutableBufferPointer { ptr in
                resultTex.getBytes(
                    ptr.baseAddress!,
                    bytesPerRow: 2 * MemoryLayout<Float>.size,
                    from: MTLRegionMake2D(0, 0, 2, 1),
                    mipmapLevel: 0
                )
            }
            // pixels[1] is the variance, normalized to the texture's
            // value range. Our Laplacian destination is r16Float in
            // [-1, 1] (Metal clamps); to get variance back in the
            // "raw byte" scale familiar from OpenCV / PyImageSearch
            // we multiply by 255² (squared because variance scales
            // quadratically with the value range).
            let normalizedVariance = pixels[1]
            return normalizedVariance * 255.0 * 255.0
        }
    }
}
