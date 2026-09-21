import Foundation

/// Media type of an asset, mirroring the subset of `PHAssetMediaType` the
/// engine cares about.
public enum AssetMediaType: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case unknown
}

/// Where an asset came from. Mirrors `PHAssetSourceType` but stays
/// platform-neutral so folder-based callers can map onto `.userLibrary`.
///
/// Only `.userLibrary` assets may be deleted: `.iTunesSynced` cannot be
/// deleted through PhotoKit at all and `.cloudShared` assets belong to a
/// shared album — one undeletable asset fails a whole `performChanges`
/// transaction, so the filter happens here, at the model layer, long
/// before any commit screen.
public enum AssetSourceType: String, Codable, Hashable, Sendable {
    case userLibrary
    case iTunesSynced
    case cloudShared
    case other

    public var isDeletable: Bool { self == .userLibrary }
}

/// Platform-neutral description of one photo-library asset.
///
/// `PickroomCore` never imports PhotoKit: the app layer fills these records
/// from `PHAsset`, and every later stage (quality assessment, fingerprints,
/// aesthetics, face capture quality) attaches its results onto the same
/// record. The engine reads only what it needs and ignores the rest.
public struct AssetRecord: Identifiable, Hashable, Sendable {
    /// Stable key for persisted state: `photos:<localIdentifier>` on iOS.
    /// Never an ephemeral scan UUID.
    public let key: String

    /// Capture date. `nil` (or a degenerate timestamp) lands the asset in
    /// the unknown-date bucket, which takes part in exact-duplicate
    /// detection only. Never file mtime.
    public let capturedAt: Date?

    /// Modification date; part of the fingerprint cache key.
    public let modificationDate: Date?

    public let mediaType: AssetMediaType

    public let isScreenshot: Bool
    public let isScreenRecording: Bool
    public let isLivePhoto: Bool

    public let burstIdentifier: String?
    /// `PHAssetBurstSelectionType.userPick` — Apple already solved the
    /// keeper for bursts; costs nothing to read.
    public let isBurstUserPick: Bool
    /// `PHAssetBurstSelectionType.autoPick`.
    public let isBurstAutoPick: Bool

    public let sourceType: AssetSourceType
    public let isFavorite: Bool

    public let cameraModel: String?

    /// Exposure bias in EV, when reported. Bracket detection input.
    public var exposureBias: Double?

    /// True when the asset carries edit/adjustment data (an edited photo,
    /// or an asset an edit depends on). Such assets default to keep-all
    /// and never receive a deletion proposal — see the `versions` guard.
    public var isEditedVersion: Bool

    /// Duration for videos, `nil` for stills.
    public let duration: TimeInterval?

    public let pixelWidth: Int
    public let pixelHeight: Int

    public let fileName: String?

    /// Stage A′ result: failed-frame tiers. Attached after a cheap
    /// 256 px analysis; independent of grouping.
    public var quality: QualityAssessment?

    /// `VNCalculateImageAestheticsScoresRequest` result: `overallScore` and
    /// the `isUtility` flag — the best `expiredUtility` classifier.
    public var aestheticsScore: Double?
    public var isUtility: Bool?

    /// Minimum face-capture quality across detected faces (one person
    /// blinking ruins the frame, so the minimum, not the mean).
    public var faceCaptureQuality: Double?

    /// Stage B result: feature print with pinned revision and
    /// crop-and-scale option.
    public var fingerprint: Fingerprint?

    /// True when this asset's analysis ran on a small local stand-in
    /// rendition — an iCloud-only asset whose original is not on the
    /// device. Rankings that include such members report low confidence;
    /// the network is never reached to score.
    public var scoredFromStandIn: Bool

    /// Content hash over resource bytes (e.g. SHA-256 of the original
    /// photo resource). Equal hashes across assets mean exact duplicates —
    /// the one category where time distance is irrelevant.
    public var contentHash: Data?

    public init(
        key: String,
        capturedAt: Date?,
        modificationDate: Date? = nil,
        mediaType: AssetMediaType = .image,
        isScreenshot: Bool = false,
        isScreenRecording: Bool = false,
        isLivePhoto: Bool = false,
        burstIdentifier: String? = nil,
        isBurstUserPick: Bool = false,
        isBurstAutoPick: Bool = false,
        sourceType: AssetSourceType = .userLibrary,
        isFavorite: Bool = false,
        cameraModel: String? = nil,
        exposureBias: Double? = nil,
        isEditedVersion: Bool = false,
        duration: TimeInterval? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        fileName: String? = nil,
        quality: QualityAssessment? = nil,
        aestheticsScore: Double? = nil,
        isUtility: Bool? = nil,
        faceCaptureQuality: Double? = nil,
        fingerprint: Fingerprint? = nil,
        scoredFromStandIn: Bool = false,
        contentHash: Data? = nil
    ) {
        self.key = key
        self.capturedAt = capturedAt
        self.modificationDate = modificationDate
        self.mediaType = mediaType
        self.isScreenshot = isScreenshot
        self.isScreenRecording = isScreenRecording
        self.isLivePhoto = isLivePhoto
        self.burstIdentifier = burstIdentifier
        self.isBurstUserPick = isBurstUserPick
        self.isBurstAutoPick = isBurstAutoPick
        self.sourceType = sourceType
        self.isFavorite = isFavorite
        self.cameraModel = cameraModel
        self.exposureBias = exposureBias
        self.isEditedVersion = isEditedVersion
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileName = fileName
        self.quality = quality
        self.aestheticsScore = aestheticsScore
        self.isUtility = isUtility
        self.faceCaptureQuality = faceCaptureQuality
        self.fingerprint = fingerprint
        self.scoredFromStandIn = scoredFromStandIn
        self.contentHash = contentHash
    }

    public var id: String { key }

    /// An asset that can never take part in a deletion proposal.
    public var isUndeletable: Bool { !sourceType.isDeletable }

    /// Whether the engine may pre-mark this asset for removal. Beyond
    /// deletability, a favourite is the user's own explicit statement
    /// that the photo matters: nothing automatic ever proposes it. The
    /// user can still mark it by hand.
    public var isProposable: Bool { sourceType.isDeletable && !isFavorite }

    /// Utility classification: screenshots and screen recordings are
    /// expired-utility candidates regardless of aesthetics; the Vision
    /// `isUtility` flag catches the rest (receipts, saved-from-messenger).
    public var isExpiredUtilityByMetadata: Bool {
        isScreenshot || isScreenRecording
    }

    /// Videos other than screen recordings are categorised, never triaged:
    /// no grouping, no ranking, no deletion proposal.
    public var isContainedVideo: Bool {
        mediaType == .video && !isScreenRecording
    }
}
