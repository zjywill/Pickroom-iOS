import Foundation

/// Confidence of a ranking. `.low` when scored from a local stand-in
/// rendition (an iCloud-only asset whose original is not on the device).
public enum ScoreConfidence: String, Codable, Hashable, Sendable {
    case high
    case low
}

/// One member's rank result. The ranking's load-bearing end is the
/// bottom — knowing which frames are objectively unusable drives the
/// default action — so `reasons` are plain language and always shown.
public struct ShotScore: Codable, Hashable, Sendable {
    public let key: String
    /// Normalised within the group (z-scores), 0…1 for display.
    public let total: Double
    public let reasons: [String]
    public let confidence: ScoreConfidence

    public init(
        key: String,
        total: Double,
        reasons: [String] = [],
        confidence: ScoreConfidence = .high
    ) {
        self.key = key
        self.total = total
        self.reasons = reasons
        self.confidence = confidence
    }
}

/// Ranks the members of one group. The ladder (best first):
///
/// 1. `burstSelectionTypes` short circuit — Apple already picked.
/// 2. Face capture quality (minimum across faces).
/// 3. Aesthetics.
/// 4. Fallback: subject sharpness and exposure, normalised within the
///    group.
///
/// The implementation lives in `FallbackShotRanker`; Vision-fed inputs
/// arrive as fields on `AssetRecord`, so the whole ladder stays
/// platform-neutral and testable.
public protocol ShotRanker: Sendable {
    func rank(_ members: [AssetRecord], kind: PhotoGroupKind) async -> [ShotScore]
}

/// Tie detection: within `tolerance` (fraction of the top score) the
/// ranking reports both candidates rather than breaking the tie — which of
/// two good frames the user prefers is their judgement, not the app's.
public enum Ranking {
    public static func topCandidates(
        in scores: [ShotScore],
        tolerance: Double = 0.05
    ) -> [ShotScore] {
        guard let best = scores.max(by: { $0.total < $1.total }) else { return [] }
        let cutoff = best.total * (1 - tolerance)
        return scores.filter { $0.total >= cutoff }.sorted { $0.total > $1.total }
    }
}
