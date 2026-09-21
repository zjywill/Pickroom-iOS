import Foundation

/// The floating near-duplicate threshold table. Time first, similarity
/// second: visual similarity is only ever computed inside a capture
/// session, and even there the threshold tightens as shots drift apart.
///
/// The shape is fixed; every number is a calibration constant to be
/// tuned against real libraries (§11), not a guess baked in forever.
public struct NearDuplicateThresholds: Hashable, Sendable {
    /// Gap < 3 s — burst, or a few quick presses. Very loose.
    public var burst: Double
    /// Gap 3 s – 2 min — same scene, retried. Normal.
    public var retried: Double
    /// Gap 2 min – 1 h — same activity. Strict.
    public var sameActivity: Double

    /// Provisional defaults in `VNFeaturePrintObservation.computeDistance`
    /// units: identical prints ≈ 0, same composition ≈ 0.1–0.3, different
    /// scenes ≳ 1.
    public init(
        burst: Double = 0.45,
        retried: Double = 0.35,
        sameActivity: Double = 0.25
    ) {
        self.burst = burst
        self.retried = retried
        self.sameActivity = sameActivity
    }

    /// The maximum fingerprint distance that still counts as a
    /// near-duplicate at this time gap, or `nil` when two shots this far
    /// apart are not near-duplicate candidates at all.
    public func threshold(forGap gap: TimeInterval) -> Double? {
        if gap < 3 { return burst }
        if gap < 120 { return retried }
        if gap < 3600 { return sameActivity }
        return nil
    }

    /// Hard ceiling independent of thresholds: shots more than 24 h
    /// apart are never grouped, however alike they look. The cross-year
    /// case (365 days) dies here and at the candidate stage — belt and
    /// braces, because that regression is the reason the whole design is
    /// time-first.
    public func isPairGroupable(gap: TimeInterval) -> Bool {
        guard gap >= 0, gap < 24 * 3600 else { return false }
        return threshold(forGap: gap) != nil
    }
}

/// Stage B candidate selection: fingerprint only assets Stage A already
/// placed close together in time. In a 50,000-asset library that is a few
/// thousand images, not fifty thousand.
public enum CandidateSelection {
    /// All index pairs (i < j) within one session whose time gap is at
    /// most `window`. Assets without a usable capture date — missing, or
    /// at/before `dateCutoff` (unset camera clocks stamp thousands of
    /// files with one instant, which would explode into O(n²) pairs) —
    /// never take part. Videos other than screen recordings and
    /// keep-all-guarded kinds are excluded upstream by the caller.
    public static func candidatePairs(
        _ assets: [AssetRecord],
        sessionGap: TimeInterval,
        window: TimeInterval,
        dateCutoff: Date = GroupEngineConfiguration.defaultDegenerateDateCutoff
    ) -> [(Int, Int)] {
        let dated = assets
            .enumerated()
            .compactMap { index, asset -> (Int, Date)? in
                guard let date = asset.capturedAt, date > dateCutoff else { return nil }
                return (index, date)
            }
            .sorted { $0.1 < $1.1 }

        var pairs: [(Int, Int)] = []
        guard dated.count > 1 else { return pairs }
        // Sessions: a gap strictly greater than sessionGap starts a new
        // session, so a gap of exactly sessionGap stays one session.
        var sessionStart = 0
        for position in 1..<dated.count {
            let gap = dated[position].1.timeIntervalSince(dated[position - 1].1)
            if gap > sessionGap {
                sessionStart = position
                continue
            }
            // All pairs within this session, bounded by the candidate
            // window — not just adjacent pairs, so A–C can group even
            // when A–B and B–C do not.
            var earlier = position - 1
            while earlier >= sessionStart {
                let pairGap = dated[position].1.timeIntervalSince(dated[earlier].1)
                if pairGap > window { break }
                pairs.append((dated[earlier].0, dated[position].0))
                earlier -= 1
            }
        }
        return pairs
    }
}
