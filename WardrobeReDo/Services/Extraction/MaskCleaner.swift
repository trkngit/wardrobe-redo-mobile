import CoreImage
import UIKit

/// Three-step CIFilter pipeline that turns a soft-edged segmentation
/// mask (RFDETR-Seg or Vision) into a clean binary-ish mask suitable
/// for compositing without the "color bleed" fringe.
///
/// Pipeline:
///   1. **CIColorThreshold @ 0.5** — push every pixel to 0 or 1. Kills
///      the partially-transparent fringe pixels at the silhouette where
///      the mask's confidence is borderline. Without this, a CIBlendWithMask
///      composite leaves the source RGB visible at e.g. 30 % alpha — that
///      pixel registers as `mix(skin, shirt)` in the color extractor and
///      bleeds wrong colors into the dominant-color count.
///   2. **CIMorphologyMinimum radius=1** — 1-pixel erode. Drops the
///      column of pixels at the silhouette where the mask boundary may
///      include some background. Eliminates ~90% of color bleed.
///   3. **CIGaussianBlur radius=0.5** — sub-pixel Gaussian. Anti-aliases
///      the binary edge by half a pixel so the rendered silhouette
///      doesn't look stamp-cut on retina screens, without exposing
///      enough source RGB to cause color bleed.
///
/// Net visual: hard mask without "stamp-cut" jaggies.
///
/// Returns `nil` if any filter step fails (e.g. CIFilter not available).
/// Callers are expected to fall through to the un-cleaned mask in that
/// case — `compositeMaskedItem` does this.
enum MaskCleaner {
    /// Cleans a soft-edged segmentation mask via threshold → erode → blur.
    /// See type doc for the per-step rationale.
    ///
    /// - Parameter mask: Single-channel `CIImage` — typically from
    ///   `CIImage(cvPixelBuffer:)` over a Vision or RFDETR-Seg mask.
    /// - Returns: A cleaned `CIImage` cropped back to `mask.extent`
    ///   (CIGaussianBlur expands the extent by ~3*radius). `nil` on
    ///   filter failure.
    static func clean(_ mask: CIImage) -> CIImage? {
        // Step 1: hard threshold at 0.5.
        guard let thresholded = CIFilter(name: "CIColorThreshold", parameters: [
            kCIInputImageKey: mask,
            "inputThreshold": 0.5
        ])?.outputImage else { return nil }

        // Step 2: 1-px morphological erode.
        guard let eroded = CIFilter(name: "CIMorphologyMinimum", parameters: [
            kCIInputImageKey: thresholded,
            kCIInputRadiusKey: 1.0
        ])?.outputImage else { return nil }

        // Step 3: gentle 0.5-px Gaussian blur to anti-alias the binary edge.
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: eroded,
            kCIInputRadiusKey: 0.5
        ])?.outputImage else { return nil }

        // CIGaussianBlur expands the extent — crop back to the source
        // extent so downstream compositing math is unchanged.
        return blurred.cropped(to: mask.extent)
    }
}
