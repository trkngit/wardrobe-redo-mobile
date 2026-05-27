import UIKit

/// Build 31 — caches the trimmed `UIImage` per source URL so the
/// alpha-bounds scan in `AlphaTrimmer` only runs once per image
/// per app session.
///
/// `NSCache` rather than a `Dictionary` because:
/// - It's thread-safe out of the box (the trim runs on a
///   background `Task.detached`, the read happens on MainActor).
/// - It responds to memory pressure automatically — on iOS warning
///   notifications it drops entries without us writing a listener.
/// - It honors `totalCostLimit` so a user with 500 wardrobe items
///   doesn't pin 500 trimmed thumbnails forever.
///
/// The cost is the rough JPEG byte size of the trimmed image
/// (`width * height * 4` bytes for the decoded buffer). At
/// 2048 × 2048 RGBA = 16 MB per entry pre-trim, much smaller
/// after trim. Total budget set to 30 MB which holds ~150 trimmed
/// thumbnails comfortably.
final class AlphaTrimCache: @unchecked Sendable {
    /// Process-wide singleton. The trim work is identity-keyed by
    /// URL — same URL across all surfaces produces the same trimmed
    /// output — so sharing one cache between the wardrobe grid,
    /// outfit card thumbnails, and match hero picker (future build)
    /// is the right call.
    static let shared = AlphaTrimCache()

    private let cache: NSCache<NSString, UIImage>

    private init() {
        cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 30 * 1024 * 1024
        cache.countLimit = 200
    }

    /// Look up a previously-trimmed image for `key`. Returns nil if
    /// the trim is still in progress or hasn't been requested yet.
    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Store a freshly-trimmed image. Cost estimate uses the
    /// decoded RGBA byte count so `totalCostLimit` actually bounds
    /// memory rather than entry count alone.
    func store(_ image: UIImage, forKey key: String) {
        let cost: Int
        if let cg = image.cgImage {
            cost = cg.bytesPerRow * cg.height
        } else {
            cost = 4 * Int(image.size.width * image.size.height)
        }
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Used by tests; production code shouldn't need to clear.
    func removeAll() {
        cache.removeAllObjects()
    }
}
