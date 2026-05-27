import UIKit

/// Build 31 — trims a cutout image to its tight non-transparent
/// bounds so the grid renders every item at a consistent visual
/// fill.
///
/// Background: items in the wardrobe grid look inconsistently sized
/// because each cutout has different amounts of transparent padding
/// (a tight mask hugs the garment, a loose mask leaves empty pixels
/// around it). SwiftUI's `.scaledToFit()` aspect-fits the FULL
/// image including those transparent pixels, so a tight cutout
/// fills ~80 % of the card while a loose one only ~40 %.
///
/// Trimming each image to its tight alpha bounds normalizes the
/// situation: every output has zero transparent padding, so the
/// downstream `.scaledToFit() + .padding(8 pt)` lays the garment
/// out at a uniform ~85 % of the card area regardless of mask
/// tightness or item aspect ratio.
///
/// Returns `nil` (caller falls back to the original image) when:
/// - The image has no `cgImage` (vector, EXIF-only, etc.)
/// - The pixel format isn't RGBA / BGRA where alpha is in a known
///   byte position
/// - The image is fully opaque (no transparent pixels to trim)
/// - The image is fully transparent (degenerate case — nothing to
///   show)
///
/// Threshold: alpha values < 5 / 255 are treated as transparent.
/// This ignores JPEG-compression noise + soft mask edge
/// antialiasing without over-cropping into real garment pixels.
enum AlphaTrimmer {
    /// Alpha values below this are treated as transparent. Higher
    /// values (10+) start cropping into antialiased mask edges and
    /// produce visible cropping artifacts. 5 is empirically the
    /// sweet spot for Vision + SAM2 mask outputs.
    static let alphaThreshold: UInt8 = 5

    /// Breathing margin around the tight content bounds. Without
    /// this, the trim hugs the outermost solid pixel and the result
    /// reads as cropped rather than fitted. 2 px is small enough
    /// to be invisible at typical card sizes.
    static let breathingMarginPx: Int = 2

    /// Returns a copy of `image` cropped to the smallest rectangle
    /// containing all non-transparent pixels (with a tiny breathing
    /// margin), or `nil` if no trim is needed or possible.
    static func trimmed(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }

        // Only handle the pixel formats Kingfisher + ImageIO
        // commonly produce. Other formats (e.g. CMYK, alpha-only)
        // are rare for our cutouts; bail and let the caller use the
        // original.
        let alphaInfo = cg.alphaInfo
        let hasAlpha = alphaInfo == .premultipliedLast ||
                       alphaInfo == .last ||
                       alphaInfo == .premultipliedFirst ||
                       alphaInfo == .first
        guard hasAlpha else { return nil }

        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let width = cg.width
        let height = cg.height
        let bytesPerRow = cg.bytesPerRow
        let bytesPerPixel = cg.bitsPerPixel / 8

        // Where the alpha byte lives within each 4-byte pixel
        // depends on the alpha info. `last` (premultiplied or not)
        // puts alpha at byte index 3; `first` puts it at byte 0.
        let alphaOffset: Int
        switch alphaInfo {
        case .premultipliedLast, .last:   alphaOffset = bytesPerPixel - 1
        case .premultipliedFirst, .first: alphaOffset = 0
        default:                          return nil
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let alpha = ptr[rowStart + x * bytesPerPixel + alphaOffset]
                if alpha > alphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        // No non-transparent pixels at all → nothing to crop to.
        guard maxX >= minX, maxY >= minY else { return nil }

        // If the tight bounds already cover the full image
        // (within a few pixels) the cutout is already tightly
        // packed and re-cropping is wasted work. Skip with a small
        // tolerance to avoid unnecessary CGImage allocations.
        let coverWidth = (maxX - minX + 1) >= (width - 4)
        let coverHeight = (maxY - minY + 1) >= (height - 4)
        if coverWidth && coverHeight { return nil }

        let margin = breathingMarginPx
        let cropX = max(0, minX - margin)
        let cropY = max(0, minY - margin)
        let cropWidth = min(width - cropX, maxX - minX + 1 + 2 * margin)
        let cropHeight = min(height - cropY, maxY - minY + 1 + 2 * margin)

        let rect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(
            cgImage: cropped,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }
}
