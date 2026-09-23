import Foundation
import Photos
import PhotosUI
import UIKit
import PickroomCore

/// Renders images from the photo library through
/// `PHCachingImageManager`, with a sliding prefetch window around the
/// deck position.
///
/// Analysis never touches the network: grouping and scoring work from
/// local renditions, and an iCloud-only asset is scored from the small
/// thumbnail Optimise Storage keeps on the phone. The exceptions are
/// what's on screen: `displayImage(for:)` — a photo the user opened to
/// look at, whose display-sized rendition is fetched from iCloud when it
/// isn't here — and a grid `thumbnail(for:)` with no local copy at all.
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
        // Opportunistic: for an iCloud-only original a high-quality local
        // request delivers nothing, but the small thumbnail Optimise
        // Storage keeps arrives first as the degraded image — use it.
        let options = Self.imageOptions(allowSynchronous: false)
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        var image = await Self.request(
            asset,
            manager: manager,
            targetSize: Self.thumbnailTargetSize,
            contentMode: .aspectFill,
            options: options,
            acceptDegraded: true
        )
        // Nothing local at all: the cell is on screen, so fetch a small
        // rendition from iCloud. Cancelled with the cell's task when it
        // scrolls away.
        if image == nil, !Task.isCancelled {
            let network = Self.imageOptions(allowSynchronous: false)
            network.isNetworkAccessAllowed = true
            network.deliveryMode = .opportunistic
            network.resizeMode = .fast
            image = await Self.request(
                asset,
                manager: manager,
                targetSize: Self.thumbnailTargetSize,
                contentMode: .aspectFill,
                options: network,
                acceptDegraded: true
            )
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

        let image = await Self.request(
            asset,
            manager: manager,
            targetSize: Self.cardTargetSize,
            contentMode: .aspectFit,
            options: Self.imageOptions(allowSynchronous: false),
            acceptDegraded: false
        )
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
        // Opportunistic: when the original is in iCloud the final
        // delivery is empty, and the local thumbnail delivered first is
        // scored instead (as a stand-in) — no network, and no photo left
        // unanalysed to be retried on every rescan.
        let options = Self.imageOptions(allowSynchronous: false)
        options.deliveryMode = .opportunistic
        return await Self.request(
            asset,
            manager: manager,
            targetSize: Self.analysisTargetSize,
            contentMode: .aspectFit,
            options: options,
            acceptDegraded: true
        )?.cgImage
    }

    // MARK: - Display (the user is looking)

    enum DisplayUpdate: Sendable {
        case image(UIImage, isFinal: Bool)
        /// Fetching the display rendition from iCloud, 0…1.
        case downloading(Double)
        /// Neither on the device nor reachable (offline, iCloud error).
        case unavailable
    }

    /// A photo the user opened: the local card rendition when the phone
    /// has one; otherwise whatever small copy is local first, then a
    /// display-sized rendition from iCloud (not the original, and
    /// nothing is added to the library). Only ever called for a photo on
    /// screen — analysis stays offline.
    nonisolated func displayImage(for identifier: String) -> AsyncStream<DisplayUpdate> {
        AsyncStream { continuation in
            let work = Task {
                if let local = await cardImage(for: identifier), Self.isDisplaySized(local) {
                    continuation.yield(.image(local, isFinal: true))
                    continuation.finish()
                    return
                }
                guard !Task.isCancelled else { return }
                await requestFromICloud(identifier, into: continuation)
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func requestFromICloud(
        _ identifier: String,
        into continuation: AsyncStream<DisplayUpdate>.Continuation
    ) {
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            continuation.yield(.unavailable)
            continuation.finish()
            return
        }
        let requestID = Self.startICloudRequest(asset, manager: manager, continuation: continuation) {
            [weak self] image in
            Task { await self?.storeInCache(key: identifier, image: image) }
        }
        let manager = manager
        let previous = continuation.onTermination
        continuation.onTermination = { reason in
            previous?(reason)
            manager.cancelImageRequest(requestID)
        }
    }

    /// Built outside the actor: PhotoKit calls the handlers on its own
    /// queues, and a closure formed in actor context would trap there.
    nonisolated private static func startICloudRequest(
        _ asset: PHAsset,
        manager: PHImageManager,
        continuation: AsyncStream<DisplayUpdate>.Continuation,
        onFinal: @escaping @Sendable (UIImage) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.progressHandler = { progress, error, _, _ in
            if error == nil { continuation.yield(.downloading(progress)) }
        }
        return manager.requestImage(
            for: asset,
            targetSize: cardTargetSize,
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let result {
                continuation.yield(.image(result, isFinal: !degraded))
            }
            guard !degraded else { return }
            if let result {
                onFinal(result)
            } else if (info?[PHImageCancelledKey] as? Bool) != true {
                continuation.yield(.unavailable)
            }
            continuation.finish()
        }
    }

    /// Whether a local rendition is big enough to judge a photo by, as
    /// opposed to the small thumbnail kept for an evicted original.
    nonisolated static func isDisplaySized(_ image: UIImage) -> Bool {
        let longest = max(image.size.width, image.size.height) * image.scale
        return longest >= 600
    }

    /// One image request as an async call, cancelled with the calling
    /// task — a grid scrolled past stops asking PhotoKit for its cells.
    /// With `acceptDegraded`, an empty final delivery falls back to the
    /// degraded image delivered before it.
    nonisolated private static func request(
        _ asset: PHAsset,
        manager: PHImageManager,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions,
        acceptDegraded: Bool
    ) async -> UIImage? {
        let state = RequestState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { result, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded {
                        if acceptDegraded, let result { state.fallback = result }
                        return
                    }
                    state.resume(continuation, with: result ?? (acceptDegraded ? state.fallback : nil))
                }
                state.requestID = requestID
                if Task.isCancelled { manager.cancelImageRequest(requestID) }
            }
        } onCancel: {
            if let id = state.requestID { manager.cancelImageRequest(id) }
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

/// Per-request bookkeeping shared between PhotoKit's handler and the
/// cancellation handler, which run on different threads.
private final class RequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var _requestID: PHImageRequestID?
    private var _fallback: UIImage?
    private var resumed = false

    var requestID: PHImageRequestID? {
        get { lock.withLock { _requestID } }
        set { lock.withLock { _requestID = newValue } }
    }

    var fallback: UIImage? {
        get { lock.withLock { _fallback } }
        set { lock.withLock { _fallback = newValue } }
    }

    /// Resumes once: a cancelled request still gets a final callback.
    func resume(_ continuation: CheckedContinuation<UIImage?, Never>, with image: UIImage?) {
        let first = lock.withLock {
            defer { resumed = true }
            return !resumed
        }
        if first { continuation.resume(returning: image) }
    }
}

private extension UIImage {
    /// Rough cost estimate for cache budgeting.
    var estimatedBytes: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
