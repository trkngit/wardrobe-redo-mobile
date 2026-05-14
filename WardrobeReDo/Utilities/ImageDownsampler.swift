import UIKit
import ImageIO

/// Build 26 — pure helper for camera-capture memory pressure.
///
/// The camera path in `AddItemViewModel.onCameraPhotoCaptured` was
/// crashing on real devices (Bug F): a full-resolution iPhone capture
/// is ~12 MP / ~50 MB decoded, and the SAM2 session load runs in
/// parallel against the same image. Combined with the model weights
/// the loader pulls in, that pushes past the foreground app memory
/// limit and the OS kills the process.
///
/// Library-flow captures don't crash because `PhotosPicker` returns
/// a pre-downsized representation. The fix is to make the camera path
/// behave the same way: downsample BEFORE writing `selectedImage`,
/// which is also what the ML pipeline ultimately wants — SAM2 itself
/// runs at 1024×1024 internally, so anything above ~2048 px on the
/// long edge is wasted.
///
/// Why not reuse `ImageService.resize`? That method is `private` on
/// the service instance and is used inside the save pipeline. Moving
/// it to a top-level utility lets both the save path AND the new
/// camera-capture path call into one place without touching
/// ImageService's encapsulation.
enum ImageDownsampler {
    /// Default cap for camera captures fed into the extraction
    /// pipeline. 2048 px is well above SAM2's native 1024 px input
    /// resolution but small enough that memory budget stays under
    /// 50 MB even for square 4 MP renderings.
    static let extractionMaxDimension: CGFloat = 2048

    /// Returns a copy of `image` whose long edge does not exceed
    /// `maxDimension`. Returns the original image untouched when it's
    /// already smaller. Uses `UIGraphicsImageRenderer` (the modern,
    /// scale-aware path) to preserve EXIF orientation handling —
    /// matching the existing `ImageService.resize` semantics.
    static func downsampled(_ image: UIImage, maxDimension: CGFloat = extractionMaxDimension) -> UIImage {
        let size = image.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        if ratio >= 1.0 { return image }

        let newSize = CGSize(
            width: size.width * ratio,
            height: size.height * ratio
        )
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Build 29 — memory-safe path for raw image `Data` (the library
    /// flow). Uses `CGImageSourceCreateThumbnailAtIndex` which reads
    /// the source lazily and emits a thumbnail at the requested size
    /// **without ever fully decoding the original**. Critical for
    /// modern phone photos: a 48 MP HEIC from an iPhone 16 Pro Max
    /// would be 100+ MB decoded; the lazy path keeps memory usage
    /// proportional to the thumbnail size (~12 MB at 2048 px) instead
    /// of the source.
    ///
    /// Returns `nil` if the data isn't a recognized image format or
    /// the source can't be decoded. Callers should fall back to a
    /// user-facing "couldn't load that image" message rather than
    /// crashing.
    ///
    /// `kCGImageSourceShouldCacheImmediately = true` decodes the
    /// thumbnail on the work thread so the main thread never blocks
    /// on first-render decode — matters because callers immediately
    /// hand the image to SwiftUI for layout.
    static func downsampled(from data: Data, maxDimension: CGFloat = extractionMaxDimension) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        // `kCGImageSourceThumbnailMaxPixelSize` is in pixels, not
        // points — we feed `maxDimension` directly (default 2048).
        // `kCGImageSourceCreateThumbnailWithTransform: true` applies
        // the EXIF orientation so portrait-shot photos don't render
        // sideways, matching the behavior of `UIImage(data:)`.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        // Build 30 — normalize the thumbnail to a guaranteed sRGB +
        // premultiplied-RGBA bitmap. CGImageSource preserves the
        // source colorspace (sRGB / DisplayP3 / ProPhoto / wide-gamut
        // HEIC), and the alpha info can be `.none` / `.first` /
        // `.last` / `.skipFirst` depending on the codec. Downstream
        // Vision + Core Image expect predictable byte order; some
        // versions of `VNGenerateForegroundInstanceMaskRequest`
        // crash with `EXC_BREAKPOINT` when handed a CGImage in
        // CMYK or 16-bit RGBA. Redrawing through a known-good sRGB
        // context costs one extra ~12 MB allocation (which the
        // caller is already paying for elsewhere) and guarantees a
        // safe pixel format.
        //
        // Falls back to the raw CGImageSource thumbnail if the
        // sRGB redraw fails — the alternative is to return nil,
        // which loses the user's image. The thumbnail is still a
        // legit CGImage even if its colorspace is unusual.
        let width = thumb.width
        let height = thumb.height
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                       | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            // Bitmap context allocation failed (extreme memory
            // pressure). Use the raw thumbnail — Vision still
            // accepts it on most paths.
            return UIImage(cgImage: thumb)
        }
        context.interpolationQuality = .high
        context.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else {
            return UIImage(cgImage: thumb)
        }
        return UIImage(cgImage: normalized)
    }
}
