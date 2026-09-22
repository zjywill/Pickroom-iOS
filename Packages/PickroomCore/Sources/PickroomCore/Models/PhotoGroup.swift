import Foundation

/// The four reasons a photo can have no reason to exist, plus the
/// keep-all and navigation kinds. Ordered by decision certainty, which is
/// also the order the deck serves them.
public enum PhotoGroupKind: String, Codable, CaseIterable, Sendable {
    case failedFrame
    case exactDuplicate
    case burst
    case expiredUtility
    case nearDuplicate
    case bracket
    case versions
    case session
    case video

    /// The order work is presented in: cheapest decision first
    /// (§4.6). Failed frames and exact duplicates need no grouping and no
    /// judgement; brackets and versions exist only to be swiped past.
    public var deckRank: Int {
        switch self {
        case .failedFrame: 0
        case .exactDuplicate: 1
        case .burst: 2
        case .expiredUtility: 3
        case .nearDuplicate: 4
        case .bracket, .versions: 5
        case .session: 6
        case .video: 7
        }
    }

    public var title: String {
        switch self {
        case .failedFrame: "Failed frame"
        case .exactDuplicate: "Exact duplicate"
        case .burst: "Burst"
        case .expiredUtility: "Expired utility"
        case .nearDuplicate: "Near duplicates"
        case .bracket: "Exposure bracket"
        case .versions: "Original + edit"
        case .session: "Session"
        case .video: "Video"
        }
    }

    /// Groups that must never produce a deletion proposal, whatever the
    /// fingerprint says. Getting this wrong causes real data loss.
    /// `versions` is not among them: keeping the edit and letting the
    /// separate original go is the user's stated preference.
    public var defaultsToKeepAll: Bool {
        self == .bracket || self == .session || self == .video
    }
}

/// Lifecycle of a group. `dismissed` is permanent: without it the user
/// re-reviews groups they already decided to keep on every launch.
public enum GroupState: String, Codable, Hashable, Sendable {
    case pending
    case resolved
    case dismissed
}

/// A set of assets the engine believes belongs together, with everything
/// the deck needs to render one card.
public struct PhotoGroup: Identifiable, Hashable, Sendable {
    /// Stable hash of the kind and the sorted member keys: the same
    /// members in a different order produce the same id, so persisted
    /// state survives a rescan.
    public let id: String

    public let kind: PhotoGroupKind

    /// Member `AssetRecord.key`s, sorted for stability.
    public let memberKeys: [String]

    /// The thumbnail that represents the card — the ranked best shot
    /// when ranking ran, else the first member.
    public let representativeKey: String

    public let span: DateInterval?

    /// 0…1. Drives ordering: cheapest decision first.
    public let certainty: Double

    /// Members the engine is confident are objectively bad (blurred,
    /// blinking, broken, exact-duplicate extras). The primary gesture
    /// removes exactly these. Empty for keep-all kinds and for
    /// `probablyBad`-only cards, which never receive a proposal.
    public let flaggedKeys: [String]

    /// The suggested keeper after ranking, when one exists. A suggestion,
    /// never a silent selection: "reduce to one" is a secondary action.
    public let suggestedKeeperKey: String?

    /// Human-readable situation, e.g. "14 shots · 8 blurred" or
    /// "312 screenshots from 2024". Never leads with a size.
    public let headline: String

    public var state: GroupState

    public init(
        id: String,
        kind: PhotoGroupKind,
        memberKeys: [String],
        representativeKey: String,
        span: DateInterval? = nil,
        certainty: Double,
        flaggedKeys: [String] = [],
        suggestedKeeperKey: String? = nil,
        headline: String,
        state: GroupState = .pending
    ) {
        self.id = id
        self.kind = kind
        self.memberKeys = memberKeys
        self.representativeKey = representativeKey
        self.span = span
        self.certainty = certainty
        self.flaggedKeys = flaggedKeys
        self.suggestedKeeperKey = suggestedKeeperKey
        self.headline = headline
        self.state = state
    }

    /// Deterministic group id: kind + sorted member keys, hashed.
    /// Order-independent by construction.
    public static func makeID(kind: PhotoGroupKind, memberKeys: [String]) -> String {
        let seed = kind.rawValue + "|" + memberKeys.sorted().joined(separator: "|")
        return Self.stableHash(seed)
    }

    /// FNV-1a 64-bit over UTF-8, hex-encoded. Not cryptographic, but stable
    /// across processes and platforms, which is the contract.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016x", hash)
    }
}

/// Summary of what the engine found, so one screen can tell the user
/// which situation their library is in without showing any card yet.
public struct LibrarySummary: Hashable, Sendable {
    public var totalAssets: Int
    public var videoCount: Int
    public var screenRecordingCount: Int
    public var screenshotCount: Int
    public var failedFrameCount: Int
    public var exactDuplicateCount: Int
    public var groupCount: Int

    public init(
        totalAssets: Int = 0,
        videoCount: Int = 0,
        screenRecordingCount: Int = 0,
        screenshotCount: Int = 0,
        failedFrameCount: Int = 0,
        exactDuplicateCount: Int = 0,
        groupCount: Int = 0
    ) {
        self.totalAssets = totalAssets
        self.videoCount = videoCount
        self.screenRecordingCount = screenRecordingCount
        self.screenshotCount = screenshotCount
        self.failedFrameCount = failedFrameCount
        self.exactDuplicateCount = exactDuplicateCount
        self.groupCount = groupCount
    }
}
