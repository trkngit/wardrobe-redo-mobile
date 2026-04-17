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
    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
