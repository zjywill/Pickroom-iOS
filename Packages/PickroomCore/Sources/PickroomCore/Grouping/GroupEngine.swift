import Foundation

/// Tunables for the group engine. Defaults are the calibration starting
/// points; the floating threshold table in particular must be tuned
/// against real libraries (§11 of the plan).
public struct GroupEngineConfiguration: Sendable {
    /// A capture-time gap strictly greater than this starts a new
    /// session. Sessions are the boundary for every kind of similarity:
    /// two photos in different sessions are never grouped as
    /// near-duplicates, however alike they look.
    public var sessionGap: TimeInterval

    /// Maximum time gap for a near-duplicate candidate pair, on top of
    /// the session boundary (the "> 1 h — different scene" rule).
    public var candidateWindow: TimeInterval

    public var thresholds: NearDuplicateThresholds

    /// Bracket detection: consecutive frames within this gap that show a
    /// regular exposure-bias progression.
    public var bracketMaxGap: TimeInterval
    public var bracketMinEVSpan: Double
    public var bracketMaxCount: Int

    /// Capture dates before this are treated as unset clocks (cameras
    /// with no clock produce thousands of assets stamped 2000-01-01).
    /// Such assets fall back to identifier order and take part in exact
    /// duplicate detection only.
    public var degenerateDateCutoff: Date

    /// 2005-01-01 UTC.
    public static let defaultDegenerateDateCutoff = Date(timeIntervalSince1970: 1_104_537_600)

    /// Distance metric over feature prints. The app injects the
    /// Vision-backed implementation; tests use Euclidean.
    public var metric: any FeaturePrintMetric

    /// Screenshots and screen recordings younger than this are grouped
    /// but not pre-marked — they are probably still in use.
    public var utilityExpiryAge: TimeInterval

    public init(
        sessionGap: TimeInterval = 4 * 3600,
        candidateWindow: TimeInterval = 3600,
        thresholds: NearDuplicateThresholds = NearDuplicateThresholds(),
        bracketMaxGap: TimeInterval = 15,
        bracketMinEVSpan: Double = 0.5,
        bracketMaxCount: Int = 7,
        degenerateDateCutoff: Date = GroupEngineConfiguration.defaultDegenerateDateCutoff,
        metric: any FeaturePrintMetric = EuclideanFeaturePrintMetric(),
        utilityExpiryAge: TimeInterval = 30 * 24 * 3600
    ) {
        self.utilityExpiryAge = utilityExpiryAge
        self.sessionGap = sessionGap
        self.candidateWindow = candidateWindow
        self.thresholds = thresholds
        self.bracketMaxGap = bracketMaxGap
        self.bracketMinEVSpan = bracketMinEVSpan
        self.bracketMaxCount = bracketMaxCount
        self.degenerateDateCutoff = degenerateDateCutoff
        self.metric = metric
    }
}

/// Stage A + A′ + B/C driver. Pure function over asset records and
/// persisted group state: same input, same groups, same ids — so group
/// state survives a rescan and a relaunched process.
///
/// Ordering contract (§4.6): the returned groups are sorted cheapest
/// decision first — failed frames and exact duplicates before bursts,
/// bursts before near-duplicates — and by certainty within a kind. Never
/// by bytes.
public struct GroupEngine: Sendable {
    public let configuration: GroupEngineConfiguration

    public init(configuration: GroupEngineConfiguration = GroupEngineConfiguration()) {
        self.configuration = configuration
    }

    public func makeGroups(
        assets: [AssetRecord],
        groupStates: [String: GroupState] = [:],
        now: Date = Date()
    ) -> (groups: [PhotoGroup], summary: LibrarySummary) {
        var summary = LibrarySummary(totalAssets: assets.count)

        // Videos other than screen recordings: counted, filterable, and
        // otherwise untouched. No group, no ranking, no deletion
        // proposal — a poster frame cannot support the decision.
        let containedVideos = assets.filter(\.isContainedVideo)
        summary.videoCount = containedVideos.count
        summary.screenRecordingCount = assets.filter(\.isScreenRecording).count
        summary.screenshotCount = assets.filter(\.isScreenshot).count

        let exactDuplicates = makeExactDuplicateGroups(assets)
        let consumedByDuplicates = Set(exactDuplicates.flatMap(\.memberKeys))
        summary.exactDuplicateCount = consumedByDuplicates.count

        let utility = makeExpiredUtilityGroups(
            assets.filter { !consumedByDuplicates.contains($0.key) },
            now: now
        )
        let consumedByUtility = Set(utility.flatMap(\.memberKeys))

        // Redundancy grouping over the remaining images.
        let rest = assets.filter { asset in
            !asset.isContainedVideo
                && !consumedByDuplicates.contains(asset.key)
                && !consumedByUtility.contains(asset.key)
                && asset.mediaType == .image
        }

        var groups: [PhotoGroup] = []
        groups.append(contentsOf: exactDuplicates)
        groups.append(contentsOf: utility)

        var consumed = Set<String>()
        consumed.formUnion(consumedByDuplicates)
        consumed.formUnion(consumedByUtility)

        // Bursts are keyed by burstIdentifier globally — one identifier
        // is one burst by definition. A burst whose members show an
        // exposure-bias progression is reclassified as a bracket: HDR
        // source frames are exactly the thing the bracket guard exists
        // to protect.
        let bursts = makeBurstGroups(rest)
        for group in bursts {
            groups.append(group)
            consumed.formUnion(group.memberKeys)
        }

        // Remaining assets: sessions, brackets, near duplicates.
        let ungrouped = rest.filter { !consumed.contains($0.key) }
        let sessions = cluster(intoSessions: ungrouped)

        for session in sessions {
            let brackets = makeBracketGroups(in: session)
            for group in brackets {
                groups.append(group)
                consumed.formUnion(group.memberKeys)
            }

            let fingerprintable = session.filter { !consumed.contains($0.key) }
            let nearDuplicates = makeNearDuplicateGroups(in: fingerprintable)
            for group in nearDuplicates {
                groups.append(group)
                consumed.formUnion(group.memberKeys)
            }
        }

        // Failed frames that nothing else absorbed. They need no
        // grouping: a lone unusable photo must still be surfaced.
        let failedFrames = makeFailedFrameGroups(
            ungrouped.filter { !consumed.contains($0.key) }
        )
        groups.append(contentsOf: failedFrames)
        summary.failedFrameCount = assets.filter { $0.quality?.tier == .obviouslyBroken }.count

        // Apply persisted state; the group id is stable across rescans,
        // so a dismissal recorded last month still holds.
        groups = groups.map { group in
            var updated = group
            updated.state = groupStates[group.id] ?? group.state
            return updated
        }

        groups.sort { a, b in
            if a.kind.deckRank != b.kind.deckRank {
                return a.kind.deckRank < b.kind.deckRank
            }
            if a.certainty != b.certainty {
                return a.certainty > b.certainty
            }
            return a.id < b.id
        }
        summary.groupCount = groups.count
        return (groups, summary)
    }

    // MARK: - Exact duplicates

    /// The one category where time distance is irrelevant: byte-identical
    /// files are the same file regardless of when they were taken.
    private func makeExactDuplicateGroups(_ assets: [AssetRecord]) -> [PhotoGroup] {
        var byHash: [Data: [AssetRecord]] = [:]
        for asset in assets where asset.mediaType == .image {
            guard let hash = asset.contentHash else { continue }
            byHash[hash, default: []].append(asset)
        }

        var groups: [PhotoGroup] = []
        for (_, members) in byHash where members.count > 1 {
            let sorted = members.sorted { order($0, $1) }
            let keys = sorted.map(\.key)
            // Keep one copy, flag the extras — but only extras PhotoKit
            // can actually delete. An undeletable copy (iTunes-synced,
            // shared) will remain no matter what the user does, so it is
            // the natural keeper; the deletable duplicates around it are
            // the redundant ones.
            // A favourite copy is the next-best keeper: the user already
            // said that one matters.
            let keeper = sorted.first { !$0.sourceType.isDeletable }
                ?? sorted.first(where: \.isFavorite)
                ?? sorted[0]
            let flagged = sorted
                .filter { $0.key != keeper.key && $0.isProposable }
                .map(\.key)
            groups.append(
                PhotoGroup(
                    id: PhotoGroup.makeID(kind: .exactDuplicate, memberKeys: keys),
                    kind: .exactDuplicate,
                    memberKeys: keys,
                    representativeKey: keeper.key,
                    span: span(of: sorted),
                    certainty: 0.95,
                    flaggedKeys: flagged,
                    suggestedKeeperKey: keeper.key,
                    headline: "Exact duplicate — \(keys.count) copies of the same photo"
                )
            )
        }
        return groups
    }

    // MARK: - Expired utility

    /// Screenshots and screen recordings, bucketed per year and ordered
    /// oldest-first. The signal is time decay: a screenshot from six
    /// months ago is almost certainly dead weight, so certainty rises
    /// with age and the bulk sweep is the primary action.
    private func makeExpiredUtilityGroups(
        _ assets: [AssetRecord],
        now: Date
    ) -> [PhotoGroup] {
        // Screenshots and screen recordings only. Vision's `isUtility`
        // also catches receipts, documents and saved images — the
        // user's own content, which is not "expired" by being useful.
        let utility = assets.filter(\.isExpiredUtilityByMetadata)
        guard !utility.isEmpty else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        var buckets: [Int: [AssetRecord]] = [:]
        var undated: [AssetRecord] = []
        for asset in utility {
            guard let date = usableDate(asset) else {
                undated.append(asset)
                continue
            }
            let year = calendar.component(.year, from: date)
            buckets[year, default: []].append(asset)
        }

        var groups: [PhotoGroup] = []

        func emit(_ members: [AssetRecord], label: String) {
            let sorted = members.sorted { order($0, $1) }
            let keys = sorted.map(\.key)
            // Only .userLibrary assets may be deleted — pre-filtered
            // long before the commit screen.
            // Only what has had time to expire is pre-marked: a
            // screenshot from last week is probably still in use.
            let cutoff = now.addingTimeInterval(-configuration.utilityExpiryAge)
            let deletable = sorted
                .filter { $0.isProposable && (usableDate($0).map { $0 < cutoff } ?? true) }
                .map(\.key)
            let youngest = sorted.compactMap(\.capturedAt).min() ?? now
            let age = now.timeIntervalSince(youngest)
            let certainty = min(0.9, 0.5 + 0.4 * min(age / (180 * 24 * 3600), 1))
            groups.append(
                PhotoGroup(
                    id: PhotoGroup.makeID(kind: .expiredUtility, memberKeys: keys),
                    kind: .expiredUtility,
                    memberKeys: keys,
                    representativeKey: keys.first ?? "",
                    span: span(of: sorted),
                    certainty: certainty,
                    flaggedKeys: deletable,
                    suggestedKeeperKey: nil,
                    headline: "\(keys.count) \(label)",
                    state: .pending
                )
            )
        }

        // Oldest buckets first — certainty grows with age, and the user
        // should see "screenshots from 2024" before last week's.
        for year in buckets.keys.sorted() {
            let members = buckets[year] ?? []
            let screenshots = members.filter(\.isScreenshot)
            let recordings = members.filter(\.isScreenRecording)
            let others = members.filter { !$0.isScreenshot && !$0.isScreenRecording }

            if !screenshots.isEmpty && !recordings.isEmpty {
                let merged = screenshots + recordings
                emit(merged, label: "screenshots and screen recordings from \(year)")
            } else if !screenshots.isEmpty {
                emit(screenshots, label: screenshots.count == 1 ? "screenshot from \(year)" : "screenshots from \(year)")
            } else if !recordings.isEmpty {
                emit(recordings, label: recordings.count == 1 ? "screen recording from \(year)" : "screen recordings from \(year)")
            }
            if !others.isEmpty {
                emit(others, label: others.count == 1 ? "utility image from \(year)" : "utility images from \(year)")
            }
        }
        if !undated.isEmpty {
            emit(undated, label: undated.count == 1 ? "utility image — no date" : "utility images — no date")
        }
        return groups
    }

    // MARK: - Bursts

    private func makeBurstGroups(_ assets: [AssetRecord]) -> [PhotoGroup] {
        var byBurst: [String: [AssetRecord]] = [:]
        for asset in assets {
            guard let burstID = asset.burstIdentifier else { continue }
            byBurst[burstID, default: []].append(asset)
        }

        var groups: [PhotoGroup] = []
        for (_, members) in byBurst where members.count > 1 {
            let sorted = members.sorted { order($0, $1) }
            let keys = sorted.map(\.key)

            // An AEB burst carries a burstIdentifier too. If its members
            // show a regular bias progression, the whole burst is a
            // bracket and defaults to keep-all.
            if isBracketProgression(sorted) {
                groups.append(
                    PhotoGroup(
                        id: PhotoGroup.makeID(kind: .bracket, memberKeys: keys),
                        kind: .bracket,
                        memberKeys: keys,
                        representativeKey: keys[0],
                        span: span(of: sorted),
                        certainty: 0.1,
                        flaggedKeys: [],
                        suggestedKeeperKey: nil,
                        headline: "Exposure bracket — \(keys.count) frames, keep all"
                    )
                )
                continue
            }

            // iOS adaptation of the bracket guard: PhotoKit exposes no
            // exposure bias, and an iPhone AEB burst keeps its ±EV
            // source frames, which look blown out or black by design.
            // Focus failures still flag; exposure-based badness inside a
            // burst does not — that is exactly the HDR-source signature.
            //
            // Blur is never a proposal either: a sharpness measure on a
            // small render reads sky, water, night and soft light as
            // "out of focus". It only steers which frame is suggested as
            // the keeper; the user decides what goes.
            let flagged: [String] = []
            let keeper = sorted.first { $0.isBurstUserPick } ?? sorted.first { $0.isBurstAutoPick }
            let soft = softKeys(sorted).count
            let certainty = soft == 0 ? 0.55 : min(0.87, 0.72 + 0.15 * Double(soft) / Double(max(keys.count, 1)))
            let headline = soft == 0
                ? "Burst — \(keys.count) shots"
                : "\(keys.count) shots · \(soft) may be soft"

            groups.append(
                PhotoGroup(
                    id: PhotoGroup.makeID(kind: .burst, memberKeys: keys),
                    kind: .burst,
                    memberKeys: keys,
                    representativeKey: keeper?.key ?? keys[0],
                    span: span(of: sorted),
                    certainty: certainty,
                    flaggedKeys: flagged,
                    suggestedKeeperKey: keeper?.key,
                    headline: headline
                )
            )
        }
        return groups
    }

    // MARK: - Brackets

    /// Runs of consecutive frames with a regular exposure-bias
    /// progression. Defaults to keep-all, never a deletion prompt:
    /// proposing someone delete their HDR source frames is how an app
    /// like this loses a user permanently.
    private func makeBracketGroups(in session: [AssetRecord]) -> [PhotoGroup] {
        var groups: [PhotoGroup] = []
        var run: [AssetRecord] = []

        func flush() {
            defer { run.removeAll() }
            guard isBracketProgression(run) else { return }
            let keys = run.map(\.key)
            groups.append(
                PhotoGroup(
                    id: PhotoGroup.makeID(kind: .bracket, memberKeys: keys),
                    kind: .bracket,
                    memberKeys: keys,
                    representativeKey: keys[0],
                    span: span(of: run),
                    certainty: 0.1,
                    flaggedKeys: [],
                    suggestedKeeperKey: nil,
                    headline: "Exposure bracket — \(keys.count) frames, keep all"
                )
            )
        }

        for asset in session {
            guard let bias = asset.exposureBias else {
                flush()
                continue
            }
            // Any repeat bias value or a gap beyond the window ends the
            // run — a bracket is a progression, not a pile.
            if let previous = run.last,
               let previousBias = previous.exposureBias,
               let gap = timeGap(previous, asset) {
                if gap > configuration.bracketMaxGap
                    || (previousBias * 10).rounded() == (bias * 10).rounded() {
                    flush()
                }
            }
            if run.count >= configuration.bracketMaxCount {
                flush()
            }
            run.append(asset)
        }
        flush()
        return groups
    }

    private func isBracketProgression(_ assets: [AssetRecord]) -> Bool {
        let biases = assets.compactMap(\.exposureBias)
        guard biases.count == assets.count, biases.count >= 2,
              biases.count <= configuration.bracketMaxCount else { return false }
        let span = (biases.max() ?? 0) - (biases.min() ?? 0)
        // All distinct values (to 0.1 EV) and a real EV span.
        let distinct = Set(biases.map { ($0 * 10).rounded() })
        return distinct.count == biases.count
            && span >= configuration.bracketMinEVSpan
    }

    // MARK: - Near duplicates

    /// Fingerprints inside candidate pairs, union-found into clusters.
    /// Time first, similarity second: the pair must share a session and
    /// sit inside the candidate window, and the threshold floats with
    /// the time gap.
    private func makeNearDuplicateGroups(in session: [AssetRecord]) -> [PhotoGroup] {
        guard session.count > 1 else { return [] }

        // Guarded assets never take part in near-duplicate clustering
        // as proposals; if they cluster at all, the group folds into a
        // keep-all `versions` card instead.
        let pairs = CandidateSelection.candidatePairs(
            session,
            sessionGap: configuration.sessionGap,
            window: configuration.candidateWindow,
            dateCutoff: configuration.degenerateDateCutoff
        )
        guard !pairs.isEmpty else { return [] }

        var unionFind = UnionFind(keys: session.map(\.key))
        // Margin per member key (not per root): roots drift as unions
        // merge, so the cluster margin is the max over its members.
        var margins: [String: Double] = [:]

        for (i, j) in pairs {
            let a = session[i]
            let b = session[j]
            guard
                let fa = a.fingerprint,
                let fb = b.fingerprint,
                let distance = configuration.metric.distance(fa, fb)
            else { continue }

            guard let gap = timeGap(a, b), gap >= 0 else { continue }
            guard let threshold = configuration.thresholds.threshold(forGap: gap) else {
                continue // not a candidate at this distance
            }
            guard configuration.thresholds.isPairGroupable(gap: gap) else { continue }

            if distance <= threshold {
                unionFind.union(a.key, b.key)
                let margin = (threshold - distance) / threshold
                margins[a.key] = max(margins[a.key] ?? 0, margin)
                margins[b.key] = max(margins[b.key] ?? 0, margin)
            }
        }

        var clusters: [String: [AssetRecord]] = [:]
        for asset in session {
            let root = unionFind.find(asset.key)
            clusters[root, default: []].append(asset)
        }

        var groups: [PhotoGroup] = []
        for (_, members) in clusters where members.count > 1 {
            let sorted = members.sorted { order($0, $1) }
            let keys = sorted.map(\.key)

            // Original + edit, saved as separate photos: keep the edit
            // (the newest one if there are several) and pre-mark the
            // unedited originals. The edit is what the user meant to
            // keep; the original is the leftover.
            if sorted.contains(where: \.isEditedVersion) {
                let edits = sorted.filter(\.isEditedVersion)
                let keeper = edits.first(where: \.isFavorite)
                    ?? edits.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
                    ?? edits[0]
                let originals = sorted.filter { !$0.isEditedVersion && $0.isProposable }.map(\.key)
                groups.append(
                    PhotoGroup(
                        id: PhotoGroup.makeID(kind: .versions, memberKeys: keys),
                        kind: .versions,
                        memberKeys: keys,
                        representativeKey: keeper.key,
                        span: span(of: sorted),
                        certainty: 0.8,
                        flaggedKeys: originals,
                        suggestedKeeperKey: keeper.key,
                        headline: originals.isEmpty
                            ? "Original and edited version"
                            : "Edited version — the original can go"
                    )
                )
                continue
            }

            // Focus failures only: a cluster of near-identical frames
            // with a dark and a bright member is far more likely an
            // exposure bracket imported from a camera (whose EV the
            // library may not report) than two failed shots.
            // Blur never pre-marks — see the burst note.
            let flagged: [String] = []
            let soft = softKeys(sorted).count
            let margin = sorted.compactMap { margins[$0.key] }.max() ?? 0
            let certainty = 0.3 + 0.2 * margin
            let headline = soft == 0
                ? "\(keys.count) near-identical shots"
                : "\(keys.count) near-identical shots · \(soft) may be soft"

            groups.append(
                PhotoGroup(
                    id: PhotoGroup.makeID(kind: .nearDuplicate, memberKeys: keys),
                    kind: .nearDuplicate,
                    memberKeys: keys,
                    representativeKey: keys[0],
                    span: span(of: sorted),
                    certainty: certainty,
                    flaggedKeys: flagged,
                    suggestedKeeperKey: nil,
                    headline: headline
                )
            )
        }
        return groups
    }

    // MARK: - Failed frames

    /// One card per unabsorbed bad frame. `obviouslyBroken` proposes
    /// deletion (bulk-safe tier, still shown in the commit grid before
    /// anything leaves the library). `probablyBad` is ordering only —
    /// no proposal, no bulk action, at any threshold.
    private func makeFailedFrameGroups(_ assets: [AssetRecord]) -> [PhotoGroup] {
        var groups: [PhotoGroup] = []
        for asset in assets.sorted(by: { order($0, $1) }) {
            // Only frames that are not photographs of anything get a
            // card. "Probably blurred" was mostly sky, water and night
            // shots — noise, not failures.
            guard let quality = asset.quality, quality.tier == .obviouslyBroken else { continue }
            let obviouslyBroken = quality.tier == .obviouslyBroken
            let deletable = asset.isProposable
            groups.append(
                PhotoGroup(
                    id: PhotoGroup.makeID(kind: .failedFrame, memberKeys: [asset.key]),
                    kind: .failedFrame,
                    memberKeys: [asset.key],
                    representativeKey: asset.key,
                    span: nil,
                    certainty: obviouslyBroken ? 1.0 : 0.97,
                    flaggedKeys: (obviouslyBroken && deletable) ? [asset.key] : [],
                    suggestedKeeperKey: nil,
                    headline: headline(for: quality)
                )
            )
        }
        return groups
    }

    private func headline(for quality: QualityAssessment) -> String {
        switch quality.tier {
        case .obviouslyBroken:
            quality.reasons.first ?? "Not a photograph"
        case .probablyBad:
            "Probably \(quality.reasons.first?.lowercased() ?? "unusable")"
        case .ok:
            "Failed frame"
        }
    }

    // MARK: - Time clustering

    /// Gap-based clustering on absolute capture time. A session can cross
    /// midnight or a timezone change without splitting, because no
    /// calendar boundary is ever consulted — a gap strictly greater than
    /// `sessionGap` is the only thing that starts a new session.
    private func cluster(intoSessions assets: [AssetRecord]) -> [[AssetRecord]] {
        let dated = assets
            .filter { usableDate($0) != nil }
            .sorted { order($0, $1) }
        guard !dated.isEmpty else { return [] }

        var sessions: [[AssetRecord]] = []
        var current: [AssetRecord] = []
        for asset in dated {
            if let last = current.last, let gap = timeGap(last, asset), gap > configuration.sessionGap {
                sessions.append(current)
                current = []
            }
            current.append(asset)
        }
        if !current.isEmpty { sessions.append(current) }
        return sessions
    }

    private func usableDate(_ asset: AssetRecord) -> Date? {
        guard let date = asset.capturedAt else { return nil }
        // Degenerate timestamps (unset clocks, epoch zero) fall back to
        // identifier order upstream and never join a session.
        guard date > configuration.degenerateDateCutoff else { return nil }
        return date
    }

    // MARK: - Helpers

    /// Focus-based badness only, for members of any multi-frame group:
    /// an exposure judgement among near-identical frames is more likely
    /// an HDR/bracket source frame than a failed shot.
    /// Members whose focus measure came out low (exposure excluded —
    /// that is the HDR-source signature). A description only, never a
    /// proposal.
    private func softKeys(_ assets: [AssetRecord]) -> [String] {
        assets
            .filter { asset in
                guard let quality = asset.quality, quality.isBad else { return false }
                return !quality.isExposureBased
            }
            .map(\.key)
    }

    /// Deterministic member order: by capture date when usable, else by
    /// key (identifier order) — the fallback for degenerate timestamps.
    private func order(_ a: AssetRecord, _ b: AssetRecord) -> Bool {
        switch (usableDate(a), usableDate(b)) {
        case let (da?, db?):
            if da != db { return da < db }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }
        return a.key < b.key
    }

    private func timeGap(_ a: AssetRecord, _ b: AssetRecord) -> TimeInterval? {
        guard let da = usableDate(a), let db = usableDate(b) else { return nil }
        return abs(db.timeIntervalSince(da))
    }

    private func span(of assets: [AssetRecord]) -> DateInterval? {
        let dates = assets.compactMap(usableDate)
        guard let start = dates.min(), let end = dates.max(), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

/// Lightweight union-find over string keys.
private struct UnionFind {
    private var parent: [String: String]

    init(keys: [String]) {
        parent = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })
    }

    mutating func find(_ key: String) -> String {
        var root = key
        while parent[root] ?? root != root {
            root = parent[root] ?? root
        }
        // Path compression.
        var current = key
        while parent[current] ?? current != current {
            let next = parent[current] ?? current
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: String, _ b: String) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        parent[rootB] = rootA
    }
}
