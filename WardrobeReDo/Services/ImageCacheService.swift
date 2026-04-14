import Foundation
import UIKit
import Kingfisher

/// Centralized Kingfisher image cache configuration.
/// Call `ImageCacheService.configure()` at app launch.
enum ImageCacheService {

    // MARK: - Configuration

    /// Configure Kingfisher's memory and disk cache limits.
    /// - Memory: 100 MB, evicts when app enters background.
    /// - Disk: 200 MB, 7-day expiration.
    static func configure() {
        let cache = ImageCache.default

        // Memory cache: 100 MB
        cache.memoryStorage.config.totalCostLimit = 100 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 150
        cache.memoryStorage.config.expiration = .seconds(600) // 10 min in memory

        // Disk cache: 200 MB, 7-day expiration
        cache.diskStorage.config.sizeLimit = 200 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(7)

        // Downsampling for grid thumbnails (400pt max)
        KingfisherManager.shared.defaultOptions = [
            .scaleFactor(UIScreen.main.scale),
            .cacheOriginalImage,
            .backgroundDecode,
        ]
    }

    // MARK: - Cache Stats

    /// Current disk cache size in bytes.
    static func diskCacheSize() async -> UInt {
        await withCheckedContinuation { continuation in
            ImageCache.default.calculateDiskStorageSize { result in
                switch result {
                case .success(let size):
                    continuation.resume(returning: size)
                case .failure:
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Formatted disk cache size string (e.g. "45.2 MB").
    static func formattedDiskCacheSize() async -> String {
        let bytes = await diskCacheSize()
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Cache Management

    /// Clear all cached images (memory + disk).
    static func clearCache() {
        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache()
    }

    /// Clear only expired disk entries.
    static func cleanExpired() {
        ImageCache.default.cleanExpiredDiskCache()
    }
}
