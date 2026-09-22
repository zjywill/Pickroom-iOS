import Foundation

/// The best-shot ladder, bottom rung to top:
///
/// 1. `burstSelectionTypes` — Apple already picked the keeper; free.
/// 2. Face capture quality (minimum across faces — one person blinking
///    ruins the frame).
/// 3. Aesthetics.
/// 4. Fallback: subject sharpness and exposure, z-score normalised
///    within the group.
///
/// Everything it needs arrives as fields on `AssetRecord`, so the whole
/// ladder runs platform-neutral: the app layer's Vision analysis fills
/// the fields, this type decides. Scores are computed lazily by the app
/// (only cards near the deck position) on ~512 px renditions and cached.
///
/// Two rules decide whether this feels smart or broken:
/// - Measure sharpness on the **subject** region, not the whole frame.
/// - Normalise scores **within the group** — absolute sharpness depends
///   on scene texture, and "best shot" is only meaningful relative to
///   its siblings.
public struct FallbackShotRanker: ShotRanker {
    public init() {}

    public func rank(_ members: [AssetRecord], kind: PhotoGroupKind) async -> [ShotScore] {
        guard members.count > 1 else {
            return members.map { ShotScore(key: $0.key, total: 1, confidence: confidence(for: $0)) }
        }
        // Original + edit: the edit is the one to keep.
        if kind == .versions {
            return members.map {
                ShotScore(
                    key: $0.key,
                    total: $0.isEditedVersion ? 1 : 0,
                    reasons: [$0.isEditedVersion ? "Edited version" : "Unedited original"],
                    confidence: confidence(for: $0)
                )
            }
        }
        // Brackets are not ranked; an existing user pick wins outright.
        if kind == .bracket {
            return members.map {
                ShotScore(
                    key: $0.key,
                    total: 1,
                    reasons: ["Keep all"],
                    confidence: confidence(for: $0)
                )
            }
        }

        // 1. Burst picks short circuit — skip scoring entirely.
        if members.contains(where: { $0.isBurstUserPick || $0.isBurstAutoPick }) {
            return rankByBurstPicks(members)
        }

        // 2. Face capture quality, minimum across faces.
        if members.allSatisfy({ $0.faceCaptureQuality != nil }) {
            return rankBy(members) { member in
                (member.faceCaptureQuality ?? 0, "Best face capture")
            }
        }

        // 3. Aesthetics.
        if members.allSatisfy({ $0.aestheticsScore != nil }) {
            return rankBy(members) { member in
                (member.aestheticsScore ?? 0, "Strongest composition")
            }
        }

        // 4. Fallback: subject sharpness + exposure, normalised within
        // the group. A member with no quality data ranks below any
        // measured member, never above.
        return rankByQuality(members)
    }

    // MARK: - Rungs

    private func rankByBurstPicks(_ members: [AssetRecord]) -> [ShotScore] {
        let userPicks = members.filter(\.isBurstUserPick)
        let chosen = userPicks.isEmpty ? members.filter(\.isBurstAutoPick) : userPicks
        let chosenKeys = Set(chosen.map(\.key))
        return members.map { member in
            if chosenKeys.contains(member.key) {
                return ShotScore(
                    key: member.key,
                    total: 1,
                    reasons: userPicks.isEmpty ? ["Auto-picked at capture"] : ["You picked it at capture"],
                    confidence: confidence(for: member)
                )
            }
            return ShotScore(
                key: member.key,
                total: 0,
                confidence: confidence(for: member)
            )
        }
    }

    private func rankBy(
        _ members: [AssetRecord],
        score: (AssetRecord) -> (Double, String)
    ) -> [ShotScore] {
        let raw = members.map { member in
            (member: member, value: score(member).0, reason: score(member).1)
        }
        let values = raw.map(\.value)
        let normalised = normalised(values)
        return raw
            .enumerated()
            .map { index, entry in
                let isTop = entry.value == (values.max() ?? 0)
                return ShotScore(
                    key: entry.member.key,
                    total: normalised[index],
                    reasons: isTop ? [entry.reason] : [],
                    confidence: confidence(for: entry.member)
                )
            }
    }

    private func rankByQuality(_ members: [AssetRecord]) -> [ShotScore] {
        let sharpness = members.map { $0.quality?.metrics.subjectSharpness ?? -1 }
        let exposure = members.map { exposurePenalty($0) }

        let sharpZ = normalised(sharpness)
        let exposureZ = normalised(exposure)
        let combined = zip(sharpZ, exposureZ).map { $0 * 0.7 + $1 * 0.3 }

        let bestSharp = sharpness.max() ?? 0
        let bestExposure = exposure.max() ?? 0

        return members.enumerated().map { index, member in
            var reasons: [String] = []
            if sharpness[index] >= 0 && sharpness[index] == bestSharp {
                reasons.append("Sharpest subject")
            }
            if exposure[index] >= 0 && exposure[index] == bestExposure && reasons.isEmpty {
                reasons.append("Best exposed")
            }
            if member.quality?.tier == .probablyBad || member.quality?.tier == .obviouslyBroken {
                reasons.append(member.quality?.reasons.first ?? "Unusable")
            }
            return ShotScore(
                key: member.key,
                total: combined[index],
                reasons: reasons,
                confidence: confidence(for: member)
            )
        }
    }

    // MARK: - Helpers

    /// Higher is better. Penalises clipping at both ends; 1.0 for a
    /// clean histogram.
    private func exposurePenalty(_ member: AssetRecord) -> Double {
        guard let metrics = member.quality?.metrics else { return -1 }
        return 1.0 - min(1, metrics.clippedHighlights + metrics.clippedShadows)
    }

    /// The ranker's confidence is low when a member was scored from a
    /// small local stand-in (iCloud-only asset, original not on device).
    /// The network is never reached to score — the
    /// `isNetworkAccessAllowed == false` contract holds throughout.
    private func confidence(for member: AssetRecord) -> ScoreConfidence {
        member.scoredFromStandIn ? .low : .high
    }

    /// Min-max normalisation within the group, squashed to 0…1 for
    /// display (the z-score idea with a bounded range). Degenerate when
    /// all values are equal — then everything ties at 1 and
    /// `Ranking.topCandidates` reports the tie instead of breaking it.
    private func normalised(_ values: [Double]) -> [Double] {
        guard let min = values.min(), let max = values.max() else {
            return values.map { _ in 0.5 }
        }
        let span = max - min
        guard span > 0 else { return values.map { _ in 1 } }
        return values.map { ($0 - min) / span }
    }
}
