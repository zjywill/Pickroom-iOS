import XCTest
import PickroomCore

/// Favourites are the user's own statement that a photo matters:
/// nothing automatic ever pre-marks one.
final class FavouriteProtectionTests: XCTestCase {
    private let broken = FailedFrameDetector().assess(Fixtures.solidPlane(value: 0))

    func testFavouriteIsNeverFlaggedInAnyKind() {
        let hash = Data([7, 7])
        let assets = [
            // Exact duplicates: the favourite copy is the keeper.
            Fixtures.asset("dup-a", capturedAt: Fixtures.base, contentHash: hash),
            Fixtures.asset("dup-fav", capturedAt: Fixtures.base.addingTimeInterval(5), isFavorite: true, contentHash: hash),
            // Expired utility bulk sweep.
            Fixtures.asset("shot-fav", capturedAt: Fixtures.base.addingTimeInterval(-400 * 86_400), isScreenshot: true, isFavorite: true),
            Fixtures.asset("shot-plain", capturedAt: Fixtures.base.addingTimeInterval(-400 * 86_400 + 10), isScreenshot: true),
            // A lone obviously-broken frame.
            Fixtures.asset("broken-fav", capturedAt: Fixtures.base.addingTimeInterval(90_000), isFavorite: true, quality: broken),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        for group in groups {
            for key in ["dup-fav", "shot-fav", "broken-fav"] {
                XCTAssertFalse(group.flaggedKeys.contains(key), "\(group.kind) flagged favourite \(key)")
            }
        }
        let exact = groups.first { $0.kind == .exactDuplicate }
        XCTAssertEqual(exact?.suggestedKeeperKey, "dup-fav")
        XCTAssertEqual(exact?.flaggedKeys, ["dup-a"])
        let sweep = groups.first { $0.kind == .expiredUtility }
        XCTAssertEqual(sweep?.flaggedKeys, ["shot-plain"])
    }
}

/// Brackets the library cannot report an EV for (imported from a
/// camera) must still never have their dark/bright frames pre-marked.
final class NearDuplicateExposureTests: XCTestCase {
    func testNearDuplicatesNeverFlagExposureBasedBadness() throws {
        let clipped = QualityAssessment(
            tier: .obviouslyBroken,
            metrics: QualityMetrics(
                subjectSharpness: 100, globalSharpness: 90, clippedHighlights: 0.99,
                clippedShadows: 0, frameUniformity: 0.5, subjectIsFace: false
            ),
            reasons: ["Almost entirely blown out"]
        )
        let blurred = QualityAssessment(
            tier: .probablyBad,
            metrics: QualityMetrics(
                subjectSharpness: 1, globalSharpness: 1, clippedHighlights: 0,
                clippedShadows: 0, frameUniformity: 0.5, subjectIsFace: false
            ),
            reasons: ["Out of focus or motion-blurred"]
        )
        let print = Fixtures.print([0.1, 0.2, 0.3])
        let assets = [
            Fixtures.asset("ev0", capturedAt: Fixtures.base, fingerprint: print),
            Fixtures.asset("ev-plus", capturedAt: Fixtures.base.addingTimeInterval(1), quality: clipped, fingerprint: print),
            Fixtures.asset("blur", capturedAt: Fixtures.base.addingTimeInterval(2), quality: blurred, fingerprint: print),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        let group = try XCTUnwrap(groups.first { $0.kind == .nearDuplicate })
        XCTAssertEqual(group.memberKeys.count, 3)
        XCTAssertTrue(group.flaggedKeys.isEmpty, "neither exposure nor blur pre-marks a near-duplicate")
    }
}

final class CandidateSelectionEdgeTests: XCTestCase {
    func testEmptyAndUndatedInputsProduceNoPairs() {
        XCTAssertTrue(CandidateSelection.candidatePairs([], sessionGap: 3600, window: 3600).isEmpty)
        let undated = [Fixtures.asset("a", capturedAt: nil), Fixtures.asset("b", capturedAt: nil)]
        XCTAssertTrue(CandidateSelection.candidatePairs(undated, sessionGap: 3600, window: 3600).isEmpty)
    }

    func testDegenerateClockDatesNeverBecomeCandidates() {
        let unsetClock = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01
        let assets = (0..<50).map { Fixtures.asset("cam-\($0)", capturedAt: unsetClock) }
        XCTAssertTrue(
            CandidateSelection.candidatePairs(assets, sessionGap: 4 * 3600, window: 3600).isEmpty,
            "an unset camera clock must not explode into O(n²) pairs"
        )
    }
}
