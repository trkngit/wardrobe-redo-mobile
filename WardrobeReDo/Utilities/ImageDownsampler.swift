import UIKit

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
}
