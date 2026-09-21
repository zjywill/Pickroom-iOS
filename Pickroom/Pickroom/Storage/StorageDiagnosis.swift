import Foundation
import Photos
import UIKit
import PickroomCore

/// The storage situation from the plan (§3), detected from what
/// PhotoKit and the system actually expose.
///
/// There is no public API that reports whether iCloud Photos is on. The
/// only thing that can be *proven* on device is that originals have been
/// evicted to iCloud — which means iCloud Photos with Optimise Storage.
/// Everything else ("originals are all here") is consistent with both
/// iCloud Photos off and iCloud Photos with Download and Keep Originals,
/// so the app never claims the library is local-only: understating the
/// reach of a deletion is the one mistake this screen must not make.
/// The Simulator cannot test any of this — real-device verification is
/// required before release.
enum StorageSituation: Equatable, Sendable {
    /// iCloud Photos on with originals evicted (Optimise Storage
    /// active): the phone already frees what it can; culling works but
    /// takes more photos to move the needle.
    case iCloudOptimising

    /// Full-size originals are on this phone — either iCloud Photos
    /// with "Download and Keep Originals", or iCloud Photos off. The two
    /// cannot be told apart, so the wording covers both.
    case iCloudFullCopies

    /// Library empty or sample inconclusive.
    case undetermined

    var title: String {
        switch self {
        case .iCloudOptimising: "iCloud Photos is saving space for you"
        case .iCloudFullCopies: "Full-size originals on this phone"
        case .undetermined: "Checking your library"
        }
    }

    /// What will actually help, first screen, per §3.
    var advice: String {
        switch self {
        case .iCloudOptimising:
            "Your phone already stores space-saving copies of photos it can. It is still full because tens of thousands of small copies still add up — that is exactly what group-at-a-time triage is for. Deleting now takes more photos to move the needle, and every photo you remove here is removed from iCloud and every device too."
        case .iCloudFullCopies:
            "Full-size originals are stored on this phone. If iCloud Photos is on, turning on Optimise iPhone Storage in Settings can free tens of gigabytes without deleting a single photo — check that your iCloud plan has room for the whole library first; if it doesn't, that switch won't help. If iCloud Photos is off, deleting here frees space one for one."
        case .undetermined:
            "No photos to check yet. Add some photos, or grant access, and check back."
        }
    }
}

/// Samples the library to determine the storage situation.
struct StorageDiagnosis: Sendable {
    /// How many assets to sample, spread across the whole library —
    /// Optimise Storage evicts old originals first, so the newest
    /// photos alone prove nothing.
    var sampleSize = 24

    /// Pure decision function over sampled evidence — testable without
    /// a photo library. `evictedOriginalFound` is `nil` when nothing
    /// could be sampled.
    static func situation(evictedOriginalFound: Bool?) -> StorageSituation {
        switch evictedOriginalFound {
        case true?: .iCloudOptimising
        case false?: .iCloudFullCopies
        case nil: .undetermined
        }
    }

    /// Runs the diagnosis over the real library: asks for each sampled
    /// original's bytes with the network disabled. An original that is
    /// not on the device comes back empty with `PHImageResultIsInCloudKey`
    /// — proof that iCloud Photos evicted it. (A small thumbnail request
    /// would not do: Optimise Storage keeps local thumbnails.)
    func diagnose(library: PhotoKitLibrary) async -> StorageSituation {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: .image, options: options)
        guard fetch.count > 0 else { return Self.situation(evictedOriginalFound: nil) }

        let stride = max(fetch.count / sampleSize, 1)
        var evicted = false
        for index in Swift.stride(from: 0, to: fetch.count, by: stride).prefix(sampleSize) {
            if await Self.originalIsEvicted(fetch[index]) {
                evicted = true
                break
            }
        }
        return Self.situation(evictedOriginalFound: evicted)
    }

    private static func originalIsEvicted(_ asset: PHAsset) async -> Bool {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.version = .original
        // The handler is called exactly once for data requests.
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(returning: data == nil && inCloud)
            }
        }
    }
}

/// Device storage capacity snapshot for the honest before/after report.
struct DeviceStorageSnapshot: Hashable, Sendable {
    var totalCapacity: Int64
    var availableCapacity: Int64

    static func current() -> DeviceStorageSnapshot {
        let url = URL(fileURLWithPath: "/")
        if
            let values = try? url.resourceValues(
                forKeys: [
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityForImportantUsageKey,
                ]
            ),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        {
            return DeviceStorageSnapshot(
                totalCapacity: Int64(total),
                availableCapacity: Int64(available)
            )
        }
        return DeviceStorageSnapshot(totalCapacity: 0, availableCapacity: 0)
    }
}
