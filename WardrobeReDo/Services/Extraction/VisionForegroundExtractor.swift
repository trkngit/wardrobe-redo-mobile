import CoreImage
import UIKit
import Vision

/// Raw output of Vision's foreground-instance mask request, before the
/// orchestrator decides what confidence level to assign.
///
/// `@unchecked Sendable` wraps the `CVPixelBuffer` field — Swift's
/// Sendable checker can't reason about CF types. The buffer is created
/// inside Vision's completion handler, treated as read-only after, and
/// only locked via `CVPixelBufferLockBaseAddress` when we sample it, so
/// it's safe to pass across actor boundaries.
struct ForegroundMaskResult: @unchecked Sendable {
    /// Full-resolution mask as a 1-channel (alpha-ish) pixel buffer.
    /// Pixel values in [0, 255], >128 = foreground per Vision's convention.
    let mask: CVPixelBuffer
    /// The original image composited against transparency using the mask,
    /// ready to feed to the color extractor or to store as a thumbnail.
    let maskedImage: UIImage
    /// Number of foreground instances Vision detected.
    /// 0 → nothing found. 1 → clean single-subject photo. 2+ → ambiguous
    /// (e.g. clothing + person + accessory).
    let instanceCount: Int
    /// Fraction of the frame Vision marked as foreground, in [0, 1].
    /// Used upstream to synthesize a confidence level.
    let coverageRatio: Double
}

/// Injection seam so the orchestrator can be unit-tested without the
/// Vision framework (which cannot run in the simulator).
protocol VisionForegroundExtracting: Sendable {
    func extractForeground(from image: UIImage) async -> ForegroundMaskResult?
}

/// Wraps `VNGenerateForegroundInstanceMaskRequest` (iOS 17+) so the rest
/// of the app can ask for "the clothing, cropped from the background" in
/// one call. Returns `nil` when Vision can't find any foreground instance
/// or when it's running on an unsupported OS / simulator — the caller is
/// expected to fall back to the original image.
final class VisionForegroundExtractor: VisionForegroundExtracting, @unchecked Sendable {

    private let ciContext: CIContext

    init(ciContext: CIContext = CIContext(options: nil)) {
        self.ciContext = ciContext
    }

    func extractForeground(from image: UIImage) async -> ForegroundMaskResult? {
        guard #available(iOS 17.0, *) else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        let orientation = OrientationUtil.visionOrientation(of: image)

        // VNGenerateForegroundInstanceMaskRequest requires the Neural Engine.
        // It is available on physical iOS 17+ devices but NOT in the
        // simulator. Let the request itself surface the platform error
        // so callers can fall through to the unmasked path.
        return await withCheckedContinuation { continuation in
            // Build-7 hardening: single-resume guard. The Vision request
            // has TWO paths that can resume the continuation — the
            // completion handler (lines below) and the `catch` of
            // `handler.perform`. On unsupported platforms (simulator
            // without Neural Engine, iOS 16 fallback) both paths can
            // fire for the same call, double-resuming the continuation
            // and triggering `EXC_BREAKPOINT` (a checked-continuation
            // contract violation). Wrap the resume call in a one-shot
            // gate so whichever path fires first wins.
            //
            // Reproducible on a 3840×2160 EXIF-rotated source on
            // iPhone 17 Pro simulator (build 6 + earlier) — see
            // `LargeImageProcessingTests`.
            let resumer = SingleResumer { result in
                continuation.resume(returning: result)
            }

            let request = VNGenerateForegroundInstanceMaskRequest { request, error in
                guard error == nil,
                      let observation = request.results?.first as? VNInstanceMaskObservation,
                      !observation.allInstances.isEmpty
                else {
                    resumer.fire(nil)
                    return
                }

                do {
                    let handler = VNImageRequestHandler(
                        cgImage: cgImage,
                        orientation: orientation,
                        options: [:]
                    )

                    // Full mask (every detected instance treated as one blob).
                    // Vision emits the mask as `kCVPixelFormatType_OneComponent32Float`
                    // (4 bytes/pixel, values in [0, 1]). We keep that float
                    // buffer for the CIBlendWithMask composite below, then
                    // convert it to a tightly-packed 8-bit mask before
                    // handing it off — downstream readers (IoU rig, color
                    // extractor) assume OneComponent8.
                    let floatMask = try observation.generateScaledMaskForImage(
                        forInstances: observation.allInstances,
                        from: handler
                    )

                    // Apply the mask to the source, producing a transparent
                    // background image that the color extractor can sample.
                    guard let maskedImage = self.applyMask(floatMask, to: cgImage, orientation: orientation)
                    else {
                        resumer.fire(nil)
                        return
                    }

                    guard let uint8Mask = Self.convertFloat32ToUInt8(floatMask) else {
                        resumer.fire(nil)
                        return
                    }
                    let coverage = self.coverageRatio(of: uint8Mask)

                    resumer.fire(ForegroundMaskResult(
                        mask: uint8Mask,
                        maskedImage: UIImage(cgImage: maskedImage),
                        instanceCount: observation.allInstances.count,
                        coverageRatio: coverage
                    ))
                } catch {
                    resumer.fire(nil)
                }
            }

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )

            do {
                try handler.perform([request])
                // If perform returned cleanly without the completion
                // handler firing (rare — Vision contract is that the
                // handler runs synchronously inside perform), close
                // the continuation here. The single-resume gate makes
                // this a no-op when the handler did fire.
                resumer.fire(nil)
            } catch {
                resumer.fire(nil)
            }
        }
    }

    /// One-shot resumer for a `CheckedContinuation`. Vision's request
    /// completion handler + the `handler.perform` `try/catch` block
    /// each represent a potential resume site; only the first one to
    /// fire is allowed to invoke the underlying continuation. Without
    /// this guard, an unsupported-platform code path can resume twice
    /// and trip `EXC_BREAKPOINT` from `CheckedContinuation`'s
    /// double-resume precondition.
    private final class SingleResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let action: (ForegroundMaskResult?) -> Void

        init(_ action: @escaping (ForegroundMaskResult?) -> Void) {
            self.action = action
        }

        func fire(_ result: ForegroundMaskResult?) {
            lock.lock()
            let shouldFire = !fired
            fired = true
            lock.unlock()
            if shouldFire {
                action(result)
            }
        }
    }

    // MARK: - Helpers

    /// Composite the source image with the Vision mask, producing an
    /// alpha-premultiplied CGImage that's transparent wherever the mask
    /// is < 128.
    private func applyMask(
        _ mask: CVPixelBuffer,
        to cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        let sourceCI = CIImage(cgImage: cgImage).oriented(orientation)
        let maskCI = CIImage(cvPixelBuffer: mask)

        // Scale the mask to match the source if Vision returned a
        // smaller buffer.
        let scaleX = sourceCI.extent.width / maskCI.extent.width
        let scaleY = sourceCI.extent.height / maskCI.extent.height
        let scaledMask = maskCI.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )

        // Composite source over transparent background, keyed by mask.
        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(sourceCI, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let output = blend.outputImage else { return nil }
        return ciContext.createCGImage(output, from: sourceCI.extent)
    }

    /// Fraction of the mask buffer whose pixel value > 128, i.e. the
    /// share of the frame Vision treated as foreground.
    /// Assumes a `kCVPixelFormatType_OneComponent8` buffer — callers must
    /// run `convertFloat32ToUInt8` first if they have the raw Vision mask.
    private func coverageRatio(of mask: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)

        guard let base = CVPixelBufferGetBaseAddress(mask) else { return 0 }

        var foreground: Int = 0
        let total = width * height
        guard total > 0 else { return 0 }

        for row in 0..<height {
            let rowPtr = base.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for col in 0..<width where rowPtr[col] > 128 {
                foreground += 1
            }
        }

        return Double(foreground) / Double(total)
    }

    /// Convert Vision's `kCVPixelFormatType_OneComponent32Float` mask into
    /// a tightly-packed `kCVPixelFormatType_OneComponent8` buffer so the
    /// rest of the pipeline — which assumes 8-bit pixel values — can read
    /// it correctly. Reading the raw float buffer as UInt8 produces
    /// garbage (the low byte of each float is almost always 0).
    ///
    /// Tolerates other input formats by returning the buffer unchanged if
    /// it's already OneComponent8, or `nil` if the format is unexpected.
    static func convertFloat32ToUInt8(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_OneComponent8 {
            return source
        }
        guard format == kCVPixelFormatType_OneComponent32Float else {
            return nil
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let srcBpr = CVPixelBufferGetBytesPerRow(source)
        guard let srcBase = CVPixelBufferGetBaseAddress(source) else { return nil }
        let floatsPerRow = srcBpr / MemoryLayout<Float32>.size
        let srcFloats = srcBase.assumingMemoryBound(to: Float32.self)

        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &output
        )
        guard status == kCVReturnSuccess, let dst = output else { return nil }

        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        let dstBpr = CVPixelBufferGetBytesPerRow(dst)
        guard let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let dstBytes = dstBase.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let f = srcFloats[y * floatsPerRow + x]
                // Vision docs: foreground values are non-zero, background is 0.
                // The buffer carries a smooth mask in [0, 1]; scale + clamp.
                let clamped = max(0, min(1, f))
                dstBytes[y * dstBpr + x] = UInt8(clamped * 255.0)
            }
        }

        return dst
    }
}
