import Foundation
import Photos
import ImageIO
import CryptoKit
import PickroomCore

/// The app-level access state, mapping `PHAuthorizationStatus` onto the
/// states the UI renders. `.limited` is first-class: the app works
/// correctly over a limited selection and offers the picker rather
/// than nagging.
enum AccessState: Equatable, Sendable {
    case notDetermined
    case denied
    case limited
    case authorized

    var title: String {
        switch self {
        case .notDetermined: "Welcome"
        case .denied: "No photo access"
        case .limited: "Limited photo access"
        case .authorized: "Full photo access"
        }
    }

    static func from(_ status: PHAuthorizationStatus) -> AccessState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        case .limited: .limited
        case .authorized: .authorized
        @unknown default: .denied
        }
    }
}

/// Reads the photo library into platform-neutral `AssetRecord`s.
///
/// All fetches include every asset source type — `.iTunesSynced` and
/// `.cloudShared` assets are counted like everything else — but the
/// deletion candidate set is filtered by `sourceType` right here, at
/// the library boundary, long before any commit screen: one
/// undeletable asset fails a whole `performChanges` transaction.
actor PhotoKitLibrary {
    private var registeredObserver: ChangeObserver?

    init() {}

    // MARK: - Authorization

    nonisolated func currentAccessState() -> AccessState {
        AccessState.from(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    nonisolated func requestAccess() async -> AccessState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return AccessState.from(status)
    }

    // MARK: - Fetching

    /// Loads every asset in the (possibly limited) library as an
    /// `AssetRecord`. No pixel data is touched: this is Stage A,
    /// metadata only.
    func loadAssetRecords() async -> [AssetRecord] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let fetch = PHAsset.fetchAssets(with: options)
        var records: [AssetRecord] = []
        records.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            records.append(Self.record(for: asset))
        }
        return records
    }

    /// Maps a `PHAsset` onto the platform-neutral record. Kept as a
    /// pure static function so tests can drive it with any asset.
    nonisolated static func record(for asset: PHAsset) -> AssetRecord {
        let subtypes = asset.mediaSubtypes
        let burstSelection = asset.burstSelectionTypes

        return AssetRecord(
            key: "photos:\(asset.localIdentifier)",
            capturedAt: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaType: mediaType(for: asset),
            isScreenshot: subtypes.contains(.photoScreenshot),
            isScreenRecording: subtypes.contains(.videoScreenRecording),
            isLivePhoto: subtypes.contains(.photoLive),
            burstIdentifier: asset.burstIdentifier,
            isBurstUserPick: burstSelection.contains(.userPick),
            isBurstAutoPick: burstSelection.contains(.autoPick),
            sourceType: sourceType(for: asset),
            isFavorite: asset.isFavorite,
            cameraModel: nil, // not exposed by PhotoKit on iOS
            exposureBias: nil, // filled from EXIF for bracket candidates only
            isEditedVersion: false, // filled from asset resources for near-duplicate candidates only
            duration: asset.mediaType == .video ? asset.duration : nil,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            fileName: asset.value(forKey: "filename") as? String
        )
    }

    nonisolated private static func mediaType(for asset: PHAsset) -> AssetMediaType {
        switch asset.mediaType {
        case .image: .image
        case .video: .video
        case .audio: .audio
        default: .unknown
        }
    }

    nonisolated private static func sourceType(for asset: PHAsset) -> AssetSourceType {
        switch asset.sourceType {
        case .typeUserLibrary: .userLibrary
        case .typeiTunesSynced: .iTunesSynced
        case .typeCloudShared: .cloudShared
        default: .other
        }
    }

    // MARK: - Exact-duplicate proof

    /// SHA-256 over the bytes of the asset's photo resources — the
    /// original plus, when present, the edited full-size render and a
    /// RAW+JPEG pair's alternate — in a fixed order. Equal values mean
    /// byte-identical files. Read only for assets whose analysis
    /// renditions already hash equal, and never over the network: an
    /// original that is only in iCloud reports `nil`, and an unproven
    /// pair is never called an exact duplicate.
    nonisolated static func originalHash(identifier: String) async -> Data? {
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        else { return nil }
        let photoTypes: [PHAssetResourceType] = [.photo, .fullSizePhoto, .alternatePhoto]
        let resources = PHAssetResource.assetResources(for: asset)
            .filter { photoTypes.contains($0.type) }
            .sorted { $0.type.rawValue < $1.type.rawValue }
        guard resources.contains(where: { $0.type == .photo }) else { return nil }

        let digest = LockedDigest()
        for resource in resources {
            digest.update(withUnsafeBytes(of: resource.type.rawValue.littleEndian) { Data($0) })
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let succeeded: Bool = await withCheckedContinuation { continuation in
                PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { digest.update($0) },
                    completionHandler: { error in continuation.resume(returning: error == nil) }
                )
            }
            guard succeeded else { return nil }
        }
        return digest.finalize()
    }

    // MARK: - Per-candidate metadata

    /// Whether the asset carries a Photos edit. A modification date is
    /// not evidence — iCloud sync, favouriting and metadata changes all
    /// bump it — so this reads the asset's resources for adjustment
    /// data. `assetResources(for:)` is not free, so it runs only for the
    /// near-duplicate candidates the `versions` guard can affect.
    nonisolated static func hasAdjustments(identifier: String) -> Bool {
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        else { return false }
        return PHAssetResource.assetResources(for: asset).contains {
            $0.type == .adjustmentData || $0.type == .fullSizePhoto
        }
    }

    /// Exposure bias in EV from the original's EXIF, when the original
    /// is on this device. PhotoKit exposes no exposure property, and the
    /// network is never used to fetch one: an evicted original simply
    /// reports `nil`, and the engine's focus-only flagging inside groups
    /// covers that case.
    nonisolated static func exposureBias(identifier: String) async -> Double? {
        guard
            let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            ).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.version = .original
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                guard
                    let data,
                    let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                    let bias = exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: bias.doubleValue)
            }
        }
    }

    // MARK: - Deletion candidates

    /// The pre-filter: only `.userLibrary` assets can be deleted, and a
    /// single undeletable asset fails the whole `performChanges`
    /// transaction — so undeletable assets never enter a candidate set.
    nonisolated static func deletionCandidates(
        from records: [AssetRecord],
        decisions: [String: PhotoDecision]
    ) -> [String] {
        deletionCandidates(
            from: Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }),
            decisions: decisions
        )
    }

    nonisolated static func deletionCandidates(
        from records: [String: AssetRecord],
        decisions: [String: PhotoDecision]
    ) -> [String] {
        decisions
            .filter { $0.value == .reject }
            .keys
            .filter { records[$0]?.sourceType.isDeletable == true }
            .sorted()
    }

    // MARK: - Change observation

    /// Watches for library changes (deletions in Photos, new imports)
    /// and calls back so the model can rescan.
    func observeChanges(handler: @escaping @Sendable () -> Void) {
        if let existing = registeredObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(existing)
        }
        let observer = ChangeObserver { _ in
            // Any library change triggers a rescan; the merge logic in
            // AppModel keeps valid cached analysis.
            handler()
        }
        PHPhotoLibrary.shared().register(observer)
        registeredObserver = observer
    }

    // PhotoKitLibrary lives for the app's lifetime; the observer stays
    // registered.
}

/// Minimal `PHPhotoLibraryChangeObserver` bridge for async contexts.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let handler: @Sendable (PHChange) -> Void

    init(handler: @Sendable @escaping (PHChange) -> Void) {
        self.handler = handler
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler(changeInstance)
    }
}

/// SHA-256 fed from PhotoKit's data callbacks, which arrive on its own
/// queue.
private final class LockedDigest: @unchecked Sendable {
    private let lock = NSLock()
    private var digest = SHA256()

    func update(_ data: Data) {
        lock.withLock { digest.update(data: data) }
    }

    func finalize() -> Data {
        lock.withLock { Data(digest.finalize()) }
    }
}
