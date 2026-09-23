import XCTest
@testable import PickroomCore

/// Failed-frame tiering. The tier split is the load-bearing design:
/// `obviouslyBroken` is bulk-safe, `probablyBad` is ordering only, and a
/// shallow-DOF portrait must not be flagged at all.
final class FailedFrameTieringTests: XCTestCase {
    let detector = FailedFrameDetector()

    func testSolidBlackIsObviouslyBroken() {
        let assessment = detector.assess(Fixtures.solidPlane(value: 0))
        XCTAssertEqual(assessment.tier, .obviouslyBroken)
        XCTAssertTrue(assessment.isBad)
    }

    func testSolidWhiteIsObviouslyBroken() {
        let assessment = detector.assess(Fixtures.solidPlane(value: 255))
        XCTAssertEqual(assessment.tier, .obviouslyBroken)
    }

    func testSoftFocusIsProbablyBad() {
        let assessment = detector.assess(Fixtures.softPlane())
        XCTAssertEqual(assessment.tier, .probablyBad)
        XCTAssertFalse(assessment.reasons.isEmpty)
    }

    func testSharpFrameIsOK() {
        let assessment = detector.assess(Fixtures.sharpPlane())
        XCTAssertEqual(assessment.tier, .ok)
    }

    /// The false positive that matters most: a shallow-depth-of-field
    /// portrait with a soft background is not flagged at all. Focus is
    /// judged on the subject — the face — never on the whole frame.
    func testShallowDepthOfFieldPortraitIsNotFlagged() {
        let portrait = Fixtures.shallowDepthOfFieldPlane()
        let metrics = detector.measure(portrait)
        XCTAssertGreaterThan(metrics.subjectSharpness, 12, "the face region is razor sharp")
        XCTAssertLessThan(metrics.globalSharpness, metrics.subjectSharpness, "the background is soft")
        let assessment = detector.assess(portrait)
        XCTAssertEqual(assessment.tier, .ok, "a sharp subject over a soft background is a good photograph")
    }

    /// `probablyBad` never becomes a card: "probably blurred" was
    /// mostly sky, water and night shots.
    func testProbablyBadNeverBecomesACard() throws {
        let bad = detector.assess(Fixtures.softPlane())
        XCTAssertEqual(bad.tier, .probablyBad)
        let assets = [
            Fixtures.asset("soft", capturedAt: Fixtures.base, quality: bad),
            Fixtures.asset("fine", capturedAt: Fixtures.base.addingTimeInterval(3600)),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertTrue(groups.filter { $0.kind == .failedFrame }.isEmpty)
        XCTAssertTrue(groups.allSatisfy { !$0.flaggedKeys.contains("soft") })
    }

    func testObviouslyBrokenReceivesProposal() throws {
        let broken = detector.assess(Fixtures.solidPlane(value: 0))
        let assets = [Fixtures.asset("black", capturedAt: Fixtures.base, quality: broken)]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let card = try XCTUnwrap(groups.first { $0.kind == .failedFrame })
        XCTAssertEqual(card.flaggedKeys, ["black"], "obviouslyBroken is the bulk-safe tier and may propose")
        XCTAssertEqual(card.certainty, 1.0, accuracy: 1e-9)
    }

    /// A lone failed frame needs no siblings to be surfaced — it gets
    /// its own card.
    func testLoneBadFrameIsSurfacedWithoutSiblings() {
        let bad = detector.assess(Fixtures.solidPlane(value: 0))
        let assets = [Fixtures.asset("alone", capturedAt: Fixtures.base, quality: bad)]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertEqual(groups.filter { $0.kind == .failedFrame }.count, 1)
    }
}

/// Expired-utility ordering: screenshots come back oldest-first, screen
/// recordings alongside them.
final class ExpiredUtilityOrderingTests: XCTestCase {
    func testScreenshotsOrderOldestFirst() throws {
        let thisYear = Fixtures.base
        let lastYear = thisYear.addingTimeInterval(-400 * 24 * 3600)
        let now = thisYear.addingTimeInterval(24 * 3600)
        let assets = [
            Fixtures.asset("recent-shot", capturedAt: thisYear, isScreenshot: true),
            Fixtures.asset("recent-shot-2", capturedAt: thisYear.addingTimeInterval(60), isScreenshot: true),
            Fixtures.asset("old-shot", capturedAt: lastYear, isScreenshot: true),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets, now: now)
        let utilityGroups = groups.filter { $0.kind == .expiredUtility }
        XCTAssertEqual(utilityGroups.count, 2, "one bucket per year: \(utilityGroups.map(\.headline))")

        let older = try XCTUnwrap(utilityGroups.first)
        XCTAssertEqual(older.memberKeys, ["old-shot"], "the oldest bucket comes first")
        let newer = utilityGroups.last!
        XCTAssertEqual(newer.memberKeys.first, "recent-shot", "oldest-first within the bucket")
        XCTAssertGreaterThan(older.certainty, newer.certainty, "certainty rises with age")
    }

    /// Vision's `isUtility` catches receipts and documents — the user's
    /// own content — so it never makes a photo "expired".
    func testVisionUtilityFlagAloneIsNotExpired() {
        let assets = [
            Fixtures.asset("receipt", capturedAt: Fixtures.base, isUtility: true),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertTrue(groups.filter { $0.kind == .expiredUtility }.isEmpty)
    }

    func testRecentScreenshotsAreGroupedButNotPreMarked() throws {
        let now = Fixtures.base
        let assets = [
            Fixtures.asset("last-week", capturedAt: now.addingTimeInterval(-7 * 24 * 3600), isScreenshot: true),
            Fixtures.asset("two-months", capturedAt: now.addingTimeInterval(-60 * 24 * 3600), isScreenshot: true),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets, now: now)
        let bucket = try XCTUnwrap(groups.first { $0.kind == .expiredUtility })
        XCTAssertEqual(bucket.memberKeys.count, 2)
        XCTAssertEqual(bucket.flaggedKeys, ["two-months"], "only screenshots older than 30 days are pre-marked")
    }

    func testScreenshotsMatchSystemAlbumSemantics() {
        // The metadata subtype is authoritative: a screenshot is a
        // screenshot even if it is sharp and well-exposed.
        let assets = [
            Fixtures.asset("screenshot", capturedAt: Fixtures.base, isScreenshot: true, quality: detectorOK()),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertEqual(groups.filter { $0.kind == .expiredUtility }.count, 1)
    }

    func testBulkSweepProposalCoversWholeBucket() throws {
        let old = Fixtures.base.addingTimeInterval(-200 * 24 * 3600)
        let assets = (0..<5).map {
            Fixtures.asset("shot-\($0)", capturedAt: old.addingTimeInterval(Double($0) * 60), isScreenshot: true)
        }
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let bucket = try XCTUnwrap(groups.first { $0.kind == .expiredUtility })
        XCTAssertEqual(bucket.flaggedKeys.count, 5, "the primary action sweeps the whole bucket")
        XCTAssertTrue(bucket.headline.contains("screenshots"), bucket.headline)
    }

    private func detectorOK() -> QualityAssessment {
        FailedFrameDetector().assess(Fixtures.sharpPlane())
    }
}

/// Ordering by certainty: given a mixed set, failed frames and exact
/// duplicates precede bursts, which precede near-duplicates.
final class CertaintyOrderingTests: XCTestCase {
    func testMixedSetOrdersCheapestDecisionFirst() {
        let detector = FailedFrameDetector()
        let bad = detector.assess(Fixtures.solidPlane(value: 0))
        let hash = Data([3, 3, 3])
        let identical = Fixtures.print([0.2, 0.4])
        let close = Fixtures.print([0.2, 0.395])

        let assets = [
            // near-duplicate pair (2 s apart)
            Fixtures.asset("near-a", capturedAt: Fixtures.base, fingerprint: identical),
            Fixtures.asset("near-b", capturedAt: Fixtures.base.addingTimeInterval(2), fingerprint: close),
            // burst
            Fixtures.asset("burst-1", capturedAt: Fixtures.base, burstIdentifier: "burst"),
            Fixtures.asset("burst-2", capturedAt: Fixtures.base.addingTimeInterval(0.5), burstIdentifier: "burst"),
            Fixtures.asset("burst-3", capturedAt: Fixtures.base.addingTimeInterval(1), burstIdentifier: "burst"),
            // exact duplicate
            Fixtures.asset("dup-1", capturedAt: Fixtures.base, contentHash: hash),
            Fixtures.asset("dup-2", capturedAt: Fixtures.base.addingTimeInterval(1), contentHash: hash),
            // failed frame
            Fixtures.asset("blurred", capturedAt: Fixtures.base, quality: bad),
        ]

        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let kinds = groups.map(\.kind)
        let failedIndex = try! XCTUnwrap(kinds.firstIndex(of: .failedFrame))
        let exactIndex = try! XCTUnwrap(kinds.firstIndex(of: .exactDuplicate))
        let burstIndex = try! XCTUnwrap(kinds.firstIndex(of: .burst))
        let nearIndex = try! XCTUnwrap(kinds.firstIndex(of: .nearDuplicate))

        XCTAssertLessThan(failedIndex, burstIndex, "failed frames precede bursts")
        XCTAssertLessThan(exactIndex, burstIndex, "exact duplicates precede bursts")
        XCTAssertLessThan(burstIndex, nearIndex, "bursts precede near-duplicates")
    }

    func testDeckRankOrderMatchesPlan() {
        XCTAssertEqual(
            PhotoGroupKind.allCases.sorted { $0.deckRank < $1.deckRank },
            [
                .failedFrame, .exactDuplicate, .burst, .expiredUtility,
                .nearDuplicate, .bracket, .versions, .session, .video,
            ]
        )
    }
}

/// Group identity: the same members in a different order produce the
/// same id; group state survives a rescan.
final class GroupIdentityTests: XCTestCase {
    func testSameMembersDifferentOrderProduceSameID() {
        let a = PhotoGroup.makeID(kind: .burst, memberKeys: ["photos:x", "photos:y", "photos:z"])
        let b = PhotoGroup.makeID(kind: .burst, memberKeys: ["photos:z", "photos:x", "photos:y"])
        XCTAssertEqual(a, b)
        // Different kind or membership differ.
        XCTAssertNotEqual(a, PhotoGroup.makeID(kind: .nearDuplicate, memberKeys: ["photos:x", "photos:y", "photos:z"]))
        XCTAssertNotEqual(a, PhotoGroup.makeID(kind: .burst, memberKeys: ["photos:x", "photos:y"]))
    }

    func testGroupStateSurvivesRescan() {
        let identical = Fixtures.print([0.7])
        let close = Fixtures.print([0.699])
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, fingerprint: identical),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(2), fingerprint: close),
        ]
        let engine = GroupEngine()
        let (first, _) = engine.makeGroups(assets: assets)
        let group = first[0]

        // The user dismisses this group permanently. A rescan (fresh
        // UUIDs, same keys — the app layer regenerates records from the
        // same library) must honour the dismissal.
        let (second, _) = engine.makeGroups(
            assets: assets.reversed(),
            groupStates: [group.id: .dismissed]
        )
        XCTAssertEqual(second[0].id, group.id)
        XCTAssertEqual(second[0].state, .dismissed)

        let (third, _) = engine.makeGroups(assets: assets, groupStates: [group.id: .resolved])
        XCTAssertEqual(third[0].state, .resolved)
    }
}

/// Ranking: one sharp and two blurred frames rank the sharp one first;
/// a tie inside 5% returns two candidates.
final class RankingTests: XCTestCase {
    let detector = FailedFrameDetector()

    func testSharpFrameRanksFirst() async throws {
        let sharp = detector.assess(Fixtures.sharpPlane())
        let soft = detector.assess(Fixtures.softPlane())
        let members = [
            Fixtures.asset("soft1", quality: soft),
            Fixtures.asset("sharp", quality: sharp),
            Fixtures.asset("soft2", quality: soft),
        ]
        let scores = await FallbackShotRanker().rank(members, kind: .nearDuplicate)
        let ranked = scores.sorted { $0.total > $1.total }
        XCTAssertEqual(ranked.first?.key, "sharp")
        XCTAssertEqual(ranked.first?.reasons.first, "Sharpest subject")
        XCTAssertGreaterThan(ranked.first!.total, ranked.last!.total)
    }

    func testTieInsideFivePercentReturnsTwoCandidates() {
        let scores = [
            ShotScore(key: "a", total: 0.98),
            ShotScore(key: "b", total: 0.96), // 2% below a → tie
            ShotScore(key: "c", total: 0.70), // far below
        ]
        let top = Ranking.topCandidates(in: scores)
        XCTAssertEqual(Set(top.map(\.key)), ["a", "b"], "ties are reported, not broken")
    }

    func testNoTieReturnsOneCandidate() {
        let scores = [
            ShotScore(key: "a", total: 0.98),
            ShotScore(key: "b", total: 0.90), // 8% below a → not a tie
        ]
        let top = Ranking.topCandidates(in: scores)
        XCTAssertEqual(top.map(\.key), ["a"])
    }

    func testBurstPickShortCircuitsScoring() async throws {
        let members = [
            Fixtures.asset("picked", burstIdentifier: "b", isBurstUserPick: true),
            Fixtures.asset("other", burstIdentifier: "b"),
        ]
        let scores = await FallbackShotRanker().rank(members, kind: .burst)
        let best = try XCTUnwrap(scores.max { $0.total < $1.total })
        XCTAssertEqual(best.key, "picked")
        XCTAssertEqual(best.reasons.first, "You picked it at capture")
    }

    func testFaceCaptureQualityRanksByMinimum() async throws {
        let members = [
            Fixtures.asset("everyone-smiling", faceCaptureQuality: 0.9),
            Fixtures.asset("one-blinking", faceCaptureQuality: 0.3),
        ]
        let scores = await FallbackShotRanker().rank(members, kind: .nearDuplicate)
        let best = try XCTUnwrap(scores.max { $0.total < $1.total })
        XCTAssertEqual(best.key, "everyone-smiling")
    }

    func testStandInScoringReportsLowConfidence() async {
        var standIn = Fixtures.asset("cloud-only")
        standIn.scoredFromStandIn = true
        let local = Fixtures.asset("local")
        let scores = await FallbackShotRanker().rank([standIn, local], kind: .nearDuplicate)
        XCTAssertEqual(scores.first { $0.key == "cloud-only" }?.confidence, .low)
        XCTAssertEqual(scores.first { $0.key == "local" }?.confidence, .high)
    }
}

/// Deletability: `.iTunesSynced` and `.cloudShared` assets never enter a
/// candidate set — the release gate, tested at the core layer.
final class CoreDeletabilityTests: XCTestCase {
    func testUndeletableSourcesNeverFlaggedInAnyKind() {
        let detector = FailedFrameDetector()
        let broken = detector.assess(Fixtures.solidPlane(value: 0))
        let hash = Data([5, 5])

        let assets = [
            Fixtures.asset("synced-broken", capturedAt: Fixtures.base, sourceType: .iTunesSynced, quality: broken),
            Fixtures.asset("shared-dup", capturedAt: Fixtures.base.addingTimeInterval(1), sourceType: .cloudShared, contentHash: hash),
            Fixtures.asset("user-dup", capturedAt: Fixtures.base.addingTimeInterval(2), contentHash: hash),
        ]

        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        for group in groups {
            XCTAssertFalse(
                group.flaggedKeys.contains("synced-broken"),
                "\(group.kind) flagged an undeletable asset"
            )
            XCTAssertFalse(
                group.flaggedKeys.contains("shared-dup"),
                "\(group.kind) flagged a shared asset"
            )
        }
        // The user's own copy is still proposable.
        let exact = groups.first { $0.kind == .exactDuplicate }
        XCTAssertEqual(exact?.flaggedKeys, ["user-dup"])
    }

    func testSourceTypeMapping() {
        XCTAssertTrue(AssetSourceType.userLibrary.isDeletable)
        XCTAssertFalse(AssetSourceType.iTunesSynced.isDeletable)
        XCTAssertFalse(AssetSourceType.cloudShared.isDeletable)
        XCTAssertFalse(AssetSourceType.other.isDeletable)
    }
}
