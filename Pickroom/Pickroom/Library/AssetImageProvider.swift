import Foundation
import Photos
import PhotosUI
import UIKit
import PickroomCore

/// Renders images from the photo library through
/// `PHCachingImageManager`, with a sliding prefetch window around the
/// deck position.
///
/// The no-network contract is absolute: `isNetworkAccessAllowed` is
/// `false` on every request this type issues. Grouping, scoring and the
/// deck all work from local renditions; an iCloud-only asset that has
/// no local rendition reports that fact (`nil` + degraded) instead of
/// reaching for the network.
actor AssetImageProvider {
    static let analysisTargetSize = CGSize(width: 256, height: 256)
    static let cardTargetSize = CGSize(width: 900, height: 1200)
    static let thumbnailTargetSize = CGSize(width: 200, height: 200)
    /// Thumbnails are small; a count cap keeps them bounded.
    static let thumbnailCacheLimit = 400

    private let manager = PHCachingImageManager()
    /// Memory budget for the in-memory image cache, derived from device
    /// physical memory — phones, not desks.
    private let cacheBudgetBytes: Int
    private var cache: [String: UIImage] = [:]
    private var cacheOrder: [String] = []
    private var thumbnails: [String: UIImage] = [:]
    private var thumbnailOrder: [String] = []
    /// Assets `PHCachingImageManager` is currently caching for the
    /// window, so leaving assets can be released.
    private var windowAssets: [String: PHAsset] = [:]

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        // ~10% of RAM, capped at 256 MB and floored at 64 MB — phones,
        // not desks.
        let budget = Int(min(max(physicalMemory / 10, 64 << 20), 256 << 20))
        cacheBudgetBytes = budget
    }

    // MARK: - Prefetch window

    /// Sliding window: `identifiers` is the deck's current window (the
    /// current card's members plus the next cards' representatives).
    /// Newly entering assets start caching, assets that left the window
    /// stop — so memory stays flat over a long run instead of growing
    /// with every card seen.
    func prefetch(window identifiers: [String]) {
        let wanted = Set(identifiers)
        let leaving = windowAssets.filter { !wanted.contains($0.key) }
        if !leaving.isEmpty {
            manager.stopCachingImages(
                for: Array(leaving.values),
                targetSize: Self.cardTargetSize,
                contentMode: .aspectFit,
                options: Self.imageOptions(allowSynchronous: false)
            )
            for key in leaving.keys { windowAssets[key] = nil }
        }

        let entering = identifiers.filter { windowAssets[$0] == nil }
        if !entering.isEmpty {
            var fresh: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: entering, options: nil)
                .enumerateObjects { asset, _, _ in fresh.append(asset) }
            for asset in fresh { windowAssets[asset.localIdentifier] = asset }
            manager.startCachingImages(
                for: fresh,
                targetSize: Self.cardTargetSize,
                contentMode: .aspectFit,
                options: Self.imageOptions(allowSynchronous: false)
            )
        }

        for key in cacheOrder where !wanted.contains(key) {
            cache[key] = nil
        }
        cacheOrder.removeAll { !wanted.contains($0) }
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
        windowAssets.removeAll()
    }

    /// Small square rendition for strips and grids — never a card-sized
    /// image for a 72 pt cell.
    func thumbnail(for identifier: String) async -> UIImage? {
        if let cached = thumbnails[identifier] { return cached }
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        else { return nil }
        let options = Self.imageOptions(allowSynchronous: false)
        options.resizeMode = .fast
        let image: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: Self.thumbnailTargetSize,
                contentMode: .aspectFill,
                options: options
            ) { result, _ in
                continuation.resume(returning: result)
            }
        }
        if let image {
            thumbnails[identifier] = image
            thumbnailOrder.append(identifier)
            while thumbnailOrder.count > Self.thumbnailCacheLimit {
                thumbnails[thumbnailOrder.removeFirst()] = nil
            }
        }
        return image
    }

    // MARK: - Image access

    /// Card-sized rendition for display. Network never allowed.
    func cardImage(for identifier: String) async -> UIImage? {
        if let cached = cache[identifier] { return cached }
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        else { return nil }

        let image: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: Self.cardTargetSize,
                contentMode: .aspectFit,
                options: Self.imageOptions(allowSynchronous: false)
            ) { result, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return } // wait for the full rendition
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
        if let image {
            storeInCache(key: identifier, image: image)
        }
        return image
    }

    /// Small rendition for pixel analysis (Stage A′).
    func analysisRendition(for identifier: String) async -> CGImage? {
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        else { return nil }
        return await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: Self.analysisTargetSize,
                contentMode: .aspectFit,
                options: Self.imageOptions(allowSynchronous: false)
            ) { result, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                continuation.resume(returning: result?.cgImage)
            }
        }
    }

    /// Whether a delivered analysis rendition is only a small stand-in —
    /// the original is in iCloud and PhotoKit could serve no more than a
    /// thumbnail locally. Judged from the image actually delivered, so
    /// it costs no second request; the network is never used to do
    /// better.
    nonisolated static func isStandIn(_ image: CGImage) -> Bool {
        let requested = max(analysisTargetSize.width, analysisTargetSize.height)
        return CGFloat(max(image.width, image.height)) < requested * 0.5
    }

    // MARK: - Helpers

    private func storeInCache(key: String, image: UIImage) {
        defer { trimCache() }
        cache[key] = image
        if !cacheOrder.contains(key) {
            cacheOrder.append(key)
        }
    }

    private func trimCache() {
        while cacheOrder.count > 1, totalBytes() > cacheBudgetBytes {
            let evict = cacheOrder.removeFirst()
            cache[evict] = nil
        }
    }

    private func totalBytes() -> Int {
        cache.values.reduce(0) { $0 + $1.estimatedBytes }
    }

    /// Every request in the app funnels through here so the
    /// no-network contract cannot be violated by accident.
    nonisolated static func imageOptions(allowSynchronous: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = allowSynchronous
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        return options
    }
}

private extension UIImage {
    /// Rough cost estimate for cache budgeting.
    var estimatedBytes: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
