import XCTest
@testable import PickroomCore

/// Bracket guard: three frames at exposure bias −2/0/+2 within one
/// second are `bracket` with a keep-all default, never a deletion
/// prompt — even when their fingerprints would happily group them.
final class BracketGuardTests: XCTestCase {
    private let identicalPrint = Fixtures.print([0.5, 0.5, 0.5])

    private func bracketAssets() -> [AssetRecord] {
        [
            Fixtures.asset("minus2", capturedAt: Fixtures.base, exposureBias: -2.0, fingerprint: identicalPrint),
            Fixtures.asset("zero", capturedAt: Fixtures.base.addingTimeInterval(0.5), exposureBias: 0.0, fingerprint: identicalPrint),
            Fixtures.asset("plus2", capturedAt: Fixtures.base.addingTimeInterval(1.0), exposureBias: 2.0, fingerprint: identicalPrint),
        ]
    }

    func testExposureProgressionIsBracketWithKeepAll() throws {
        let (groups, _) = GroupEngine().makeGroups(assets: bracketAssets())
        let bracket = try XCTUnwrap(groups.first { $0.kind == .bracket })
        XCTAssertEqual(Set(bracket.memberKeys), ["minus2", "zero", "plus2"])
        XCTAssertTrue(bracket.flaggedKeys.isEmpty, "a bracket never proposes deletion")
        XCTAssertTrue(bracket.kind.defaultsToKeepAll)
        XCTAssertFalse(groups.contains { $0.kind == .nearDuplicate }, "bracket members must not double-group")
    }

    func testBracketSurvivesEvenWithBrokenQuality() {
        // Even if one bracket frame is technically broken, the group
        // stays keep-all: HDR source frames are exactly what this guard
        // protects.
        var assets = bracketAssets()
        let broken = QualityAssessment(
            tier: .obviouslyBroken,
            metrics: QualityMetrics(
                subjectSharpness: 0, globalSharpness: 0, clippedHighlights: 0,
                clippedShadows: 0, frameUniformity: 0.999, subjectIsFace: false
            ),
            reasons: ["Near-uniform frame"]
        )
        assets[1].quality = broken
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let bracket = try! XCTUnwrap(groups.first { $0.kind == .bracket })
        XCTAssertTrue(bracket.flaggedKeys.isEmpty)
    }

    func testBurstWithBiasProgressionIsAlsoBracket() {
        // AEB shots carry a burstIdentifier in the photo library. If the
        // members show a bias progression the whole burst is a bracket.
        let assets = [
            Fixtures.asset("b1", capturedAt: Fixtures.base, burstIdentifier: "burst-1", exposureBias: -1.0),
            Fixtures.asset("b2", capturedAt: Fixtures.base.addingTimeInterval(0.4), burstIdentifier: "burst-1", exposureBias: 0.0),
            Fixtures.asset("b3", capturedAt: Fixtures.base.addingTimeInterval(0.8), burstIdentifier: "burst-1", exposureBias: 1.0),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertEqual(groups.filter { $0.kind == .burst }.count, 0)
        XCTAssertEqual(groups.filter { $0.kind == .bracket }.count, 1)
    }

    func testSingleBiasIsNotABracket() {
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, exposureBias: 0.0),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(1), exposureBias: 0.0),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertTrue(groups.filter { $0.kind == .bracket }.isEmpty)
    }

    func testNormalBurstStillProposesOnlyBadFrames() throws {
        let detector = FailedFrameDetector()
        let bad = detector.assess(Fixtures.softPlane())
        let assets = [
            Fixtures.asset("keep", capturedAt: Fixtures.base, burstIdentifier: "burst-2", isBurstUserPick: true),
            Fixtures.asset("soft1", capturedAt: Fixtures.base.addingTimeInterval(0.3), burstIdentifier: "burst-2", quality: bad),
            Fixtures.asset("soft2", capturedAt: Fixtures.base.addingTimeInterval(0.6), burstIdentifier: "burst-2", quality: bad),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let burst = try XCTUnwrap(groups.first { $0.kind == .burst })
        XCTAssertEqual(burst.flaggedKeys, ["soft1", "soft2"])
        XCTAssertEqual(burst.suggestedKeeperKey, "keep", "burstSelectionTypes short circuit: the user pick wins")
        XCTAssertEqual(burst.representativeKey, "keep")
        XCTAssertTrue(burst.headline.contains("2 blurred"), "headline describes the situation: \(burst.headline)")
    }

    /// Inside a burst, exposure-based badness is the signature of HDR
    /// source frames (PhotoKit exposes no exposure bias, so an iPhone
    /// AEB burst looks like one good frame plus clipped extremes).
    /// Focus failures still flag.
    func testBurstNeverFlagsExposureBasedBadness() throws {
        let exposureBad = QualityAssessment(
            tier: .obviouslyBroken,
            metrics: QualityMetrics(
                subjectSharpness: 100, globalSharpness: 90, clippedHighlights: 0.99,
                clippedShadows: 0, frameUniformity: 0.5, subjectIsFace: false
            ),
            reasons: ["Almost entirely blown out"]
        )
        let focusBad = QualityAssessment(
            tier: .probablyBad,
            metrics: QualityMetrics(
                subjectSharpness: 1, globalSharpness: 1, clippedHighlights: 0,
                clippedShadows: 0, frameUniformity: 0.5, subjectIsFace: false
            ),
            reasons: ["Out of focus or motion-blurred"]
        )
        let assets = [
            Fixtures.asset("hdr-normal", capturedAt: Fixtures.base, burstIdentifier: "burst-3"),
            Fixtures.asset("hdr-minus-ev", capturedAt: Fixtures.base.addingTimeInterval(0.3), burstIdentifier: "burst-3", quality: exposureBad),
            Fixtures.asset("hdr-plus-ev", capturedAt: Fixtures.base.addingTimeInterval(0.6), burstIdentifier: "burst-3", quality: exposureBad),
            Fixtures.asset("genuine-blur", capturedAt: Fixtures.base.addingTimeInterval(0.9), burstIdentifier: "burst-3", quality: focusBad),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let burst = try XCTUnwrap(groups.first { $0.kind == .burst })
        XCTAssertEqual(burst.flaggedKeys, ["genuine-blur"], "exposure evidence inside a burst is the HDR-source signature, not a failed frame")
    }
}

/// Versions guard: an original and its edit never form a deletion
/// prompt.
final class VersionsGuardTests: XCTestCase {
    func testOriginalAndEditNeverProposeDeletion() throws {
        let identical = Fixtures.print([0.3, 0.3])
        let assets = [
            Fixtures.asset("original", capturedAt: Fixtures.base, fingerprint: identical),
            Fixtures.asset("edited", capturedAt: Fixtures.base.addingTimeInterval(10), isEditedVersion: true, fingerprint: identical),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let versions = try XCTUnwrap(groups.first { $0.kind == .versions })
        XCTAssertEqual(Set(versions.memberKeys), ["original", "edited"])
        XCTAssertTrue(versions.flaggedKeys.isEmpty, "an edit and its original never receive a deletion prompt")
        XCTAssertTrue(versions.kind.defaultsToKeepAll)
    }
}

/// Exact duplicates: unconditionally safe, the only category where time
/// distance is irrelevant.
final class ExactDuplicateTests: XCTestCase {
    func testGroupsByContentHashDespiteTimeAndMtime() throws {
        let hash = Data(repeating: 7, count: 32)
        let assets = [
            Fixtures.asset("first", capturedAt: Fixtures.base, contentHash: hash, fileName: "IMG_0001.heic"),
            Fixtures.asset(
                "copy",
                capturedAt: Fixtures.base.addingTimeInterval(90 * 24 * 3600),
                contentHash: hash,
                fileName: "photo (1).heic"
            ),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let exact = try XCTUnwrap(groups.first { $0.kind == .exactDuplicate })
        XCTAssertEqual(exact.memberKeys.first, "first", "the earliest copy is the keeper")
        XCTAssertEqual(exact.flaggedKeys, ["copy"])
        XCTAssertEqual(exact.certainty, 0.95, accuracy: 1e-9)
    }

    func testDifferentHashesDoNotGroup() {
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, contentHash: Data([1])),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(1), contentHash: Data([2])),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertTrue(groups.filter { $0.kind == .exactDuplicate }.isEmpty)
    }

    func testUndeletableDuplicateIsNeverFlaggedButDeletableCopyIs() throws {
        let hash = Data([9, 9])
        let assets = [
            Fixtures.asset("mine", capturedAt: Fixtures.base, contentHash: hash),
            Fixtures.asset("synced", capturedAt: Fixtures.base.addingTimeInterval(5), sourceType: .iTunesSynced, contentHash: hash),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let exact = try XCTUnwrap(groups.first { $0.kind == .exactDuplicate })
        XCTAssertFalse(exact.flaggedKeys.contains("synced"), "an undeletable asset must never be flagged for deletion")
        // The synced copy cannot be removed, so it is the keeper and the
        // user's own duplicate copy is the redundant one.
        XCTAssertEqual(exact.flaggedKeys, ["mine"])
        XCTAssertEqual(exact.suggestedKeeperKey, "synced")
    }
}

/// Video containment: a screen recording classifies as
/// `expiredUtility`; every other video is counted in the video category
/// and enters **no** group, no ranking, and no deletion proposal.
final class VideoContainmentTests: XCTestCase {
    func testScreenRecordingJoinsExpiredUtility() throws {
        let old = Fixtures.base.addingTimeInterval(-200 * 24 * 3600)
        let assets = [
            Fixtures.asset("rec1", capturedAt: old, mediaType: .video, isScreenRecording: true, duration: 120),
            Fixtures.asset("rec2", capturedAt: old.addingTimeInterval(60), mediaType: .video, isScreenRecording: true, duration: 30),
        ]
        let (groups, summary) = GroupEngine().makeGroups(assets: assets)
        let utility = try XCTUnwrap(groups.first { $0.kind == .expiredUtility })
        XCTAssertTrue(utility.headline.contains("screen recording"), utility.headline)
        XCTAssertEqual(utility.memberKeys.count, 2)
        XCTAssertEqual(summary.screenRecordingCount, 2)
        XCTAssertEqual(summary.videoCount, 0, "screen recordings are not video-category")
    }

    func testVideosNeverEnterAnyGroupOrProposal() {
        let assets = [
            Fixtures.asset("clip1", capturedAt: Fixtures.base, mediaType: .video, duration: 60),
            Fixtures.asset("clip2", capturedAt: Fixtures.base.addingTimeInterval(2), mediaType: .video, duration: 1200),
            Fixtures.asset("shot", capturedAt: Fixtures.base.addingTimeInterval(4)),
        ]
        let (groups, summary) = GroupEngine().makeGroups(assets: assets)
        let videoMembers = groups.flatMap(\.memberKeys)
        XCTAssertFalse(videoMembers.contains("clip1"))
        XCTAssertFalse(videoMembers.contains("clip2"))
        XCTAssertTrue(groups.allSatisfy { !$0.flaggedKeys.contains("clip1") && !$0.flaggedKeys.contains("clip2") })
        XCTAssertEqual(summary.videoCount, 2)
    }

    func testVideosAreNotRanked() async throws {
        let ranker = FallbackShotRanker()
        let scores = await ranker.rank(
            [
                Fixtures.asset("clip", mediaType: .video, duration: 10),
                Fixtures.asset("clip2", mediaType: .video, duration: 10),
            ],
            kind: .video
        )
        XCTAssertEqual(scores.count, 2)
        // Rankers refuse to compare videos: equal, reason-free scores.
        XCTAssertTrue(scores.allSatisfy { $0.reasons.isEmpty })
        XCTAssertEqual(scores.map(\.total), [1, 1])
    }
}
