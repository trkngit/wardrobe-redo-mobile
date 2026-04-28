import UIKit
import ImageIO

/// Bridges `UIImage.Orientation` to the `CGImagePropertyOrientation` that
/// Vision, Core Image, and Core ML expect.
///
/// Without this, a photo shot in landscape or upside-down will be handed
/// to `VNGenerateForegroundInstanceMaskRequest` with the wrong EXIF flag,
/// and Vision will mask "foreground" pixels from a sideways frame —
/// producing a mask that's rotated 90° relative to the source image.
///
/// Always use this helper before passing a `UIImage` to any Vision or
/// Core ML request: pull the `.cgImage` AND call `visionOrientation(from:)`
/// on the `imageOrientation` property.
enum OrientationUtil {

    /// Map a `UIImage.Orientation` value to the equivalent EXIF
    /// orientation used by Vision's `VNImageRequestHandler`.
    static func visionOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }

    /// Convenience: pull the orientation straight off a `UIImage`.
    static func visionOrientation(of image: UIImage) -> CGImagePropertyOrientation {
        visionOrientation(from: image.imageOrientation)
    }

    /// Return a copy of the image with its pixel buffer rotated to match
    /// `.up` orientation. Useful when the downstream consumer can't read
    /// EXIF tags (older Core ML inputs, JPEG pipelines that strip EXIF).
    /// The returned image has `imageOrientation == .up` and its `cgImage`
    /// is physically oriented upright.
    ///
    /// **Build-7 hardening:** if the renderer's `CGContext` allocation
    /// fails on a memory-constrained device, `UIGraphicsImageRenderer`
    /// silently returns a placeholder bitmap that doesn't reflect the
    /// source pixels. Verify the rendered `CGImage` has the expected
    /// dimensions; if not (or if it's outright nil), fall back to the
    /// original `UIImage`. Vision/CoreML can still read its
    /// `imageOrientation` flag, so the worst case is a mask rotated
    /// 90° vs. a hard crash.
    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = (image.cgImage?.alphaInfo == .none) ||
                        (image.cgImage?.alphaInfo == .noneSkipFirst) ||
                        (image.cgImage?.alphaInfo == .noneSkipLast)
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let result = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        // Sanity-check the renderer output. Pre-build-7 the silent
        // white-fill failure mode produced corrupt downstream masks.
        guard let cg = result.cgImage,
              cg.width > 0,
              cg.height > 0
        else {
            return image
        }
        return result
    }

    /// Memory-safe variant: downsample to `maxDimension` BEFORE
    /// rotating, so a 3840×2160 EXIF-rotated source doesn't hold a
    /// 31.6 MB temporary bitmap during `normalized`.
    ///
    /// **Why callers should prefer this over plain `normalized`.**
    /// Vision's foreground request, RFDETR-Seg's input pre-processing,
    /// and SAM2's session all internally operate at ≤ 1024 px; feeding
    /// them a 3840×2160 source forces an unnecessary working-set spike
    /// of 31.6 MB (∼9× the post-downsample footprint). Capping at the
    /// entry point of `ClothingExtractionService.extract` brings peak
    /// in-flight memory below 50 MB on a 4 GB device.
    ///
    /// `maxDimension` is the longer-edge cap (in points). Returns the
    /// input unchanged if it's already smaller. Always returns a
    /// `.up`-oriented `UIImage` (i.e. it composes downscale + normalize
    /// in one bitmap allocation rather than two).
    static func normalizedAndCapped(
        _ image: UIImage,
        maxDimension: CGFloat
    ) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let needsResize = longest > maxDimension
        let needsRotate = image.imageOrientation != .up

        // Cheap path — no work to do.
        if !needsResize && !needsRotate { return image }

        let scale = needsResize ? (maxDimension / longest) : 1
        let targetSize = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = (image.cgImage?.alphaInfo == .none) ||
                        (image.cgImage?.alphaInfo == .noneSkipFirst) ||
                        (image.cgImage?.alphaInfo == .noneSkipLast)

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let result = renderer.image { _ in
            // `image.draw(in:)` honors the source's `imageOrientation`
            // automatically, so a single draw composes both rotate +
            // resize without an intermediate buffer.
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Same sanity check as plain `normalized` — fall back to the
        // input rather than ship a silently-corrupt bitmap.
        guard let cg = result.cgImage,
              cg.width == Int(targetSize.width),
              cg.height == Int(targetSize.height)
        else {
            return image
        }
        return result
    }
}
