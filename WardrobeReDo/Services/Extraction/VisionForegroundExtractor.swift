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
            let request = VNGenerateForegroundInstanceMaskRequest { request, error in
                guard error == nil,
                      let observation = request.results?.first as? VNInstanceMaskObservation,
                      !observation.allInstances.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let handler = VNImageRequestHandler(
                        cgImage: cgImage,
                        orientation: orientation,
                        options: [:]
                    )

                    // Full mask (every detected instance treated as one blob).
                    let maskBuffer = try observation.generateScaledMaskForImage(
                        forInstances: observation.allInstances,
                        from: handler
                    )

                    // Apply the mask to the source, producing a transparent
                    // background image that the color extractor can sample.
                    guard let maskedImage = self.applyMask(maskBuffer, to: cgImage, orientation: orientation)
                    else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let coverage = self.coverageRatio(of: maskBuffer)

                    continuation.resume(returning: ForegroundMaskResult(
                        mask: maskBuffer,
                        maskedImage: UIImage(cgImage: maskedImage),
                        instanceCount: observation.allInstances.count,
                        coverageRatio: coverage
                    ))
                } catch {
                    continuation.resume(returning: nil)
                }
            }

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
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
}
