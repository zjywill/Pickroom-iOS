import XCTest
import PickroomCore
@testable import Pickroom

/// Permission states render correctly; the three-way diagnosis maps
/// onto the right advice; Recently Deleted accounting works; the
/// commit wording matches what will actually happen.
final class AppLayerTests: XCTestCase {
    // MARK: - Access states

    func testAccessStateMapping() {
        XCTAssertEqual(AccessState.from(.notDetermined), .notDetermined)
        XCTAssertEqual(AccessState.from(.denied), .denied)
        XCTAssertEqual(AccessState.from(.restricted), .denied)
        XCTAssertEqual(AccessState.from(.limited), .limited)
        XCTAssertEqual(AccessState.from(.authorized), .authorized)
    }

    func testEveryAccessStateHasATitle() {
        for state: AccessState in [.notDetermined, .denied, .limited, .authorized] {
            XCTAssertFalse(state.title.isEmpty)
        }
    }

    // MARK: - Storage diagnosis

    func testEvictedOriginalMeansOptimising() {
        XCTAssertEqual(StorageDiagnosis.situation(evictedOriginalFound: true), .iCloudOptimising)
    }

    func testAllOriginalsLocalMeansFullCopiesNeverLocalOnly() {
        // iCloud Photos off and "Download and Keep Originals" look the
        // same on device; the app must not claim the library is local.
        XCTAssertEqual(StorageDiagnosis.situation(evictedOriginalFound: false), .iCloudFullCopies)
    }

    func testNothingSampledIsUndetermined() {
        XCTAssertEqual(StorageDiagnosis.situation(evictedOriginalFound: nil), .undetermined)
    }

    func testAdviceCoversBothPossibilitiesWhereTheyCannotBeToldApart() {
        XCTAssertTrue(StorageSituation.iCloudOptimising.advice.contains("iCloud"))
        let fullCopies = StorageSituation.iCloudFullCopies.advice
        XCTAssertTrue(fullCopies.contains("Optimise iPhone Storage"))
        XCTAssertTrue(fullCopies.contains("one for one"))
        XCTAssertTrue(fullCopies.contains("iCloud plan"), "the advice is useless when iCloud is full")
    }

    // MARK: - Commit wording

    func testCommitHeadlineWhenICloudIsProven() {
        XCTAssertEqual(
            CommitComposer.headline(count: 1240, situation: .iCloudOptimising),
            "Delete 1,240 photos from iCloud and all your devices"
        )
    }

    func testCommitHeadlineNeverUnderstatesReachWhenUnproven() {
        for situation: StorageSituation in [.iCloudFullCopies, .undetermined] {
            let headline = CommitComposer.headline(count: 1, situation: situation)
            XCTAssertTrue(headline.hasPrefix("Delete 1 photo"), headline)
            XCTAssertTrue(headline.contains("iCloud and all your devices"), headline)
        }
    }

    func testSupportingLineAlwaysStatesTheGracePeriod() {
        let line = CommitComposer.supportingLine()
        XCTAssertTrue(line.contains("Recently Deleted"))
        XCTAssertTrue(line.contains("30 days"))
        XCTAssertTrue(line.contains("syncs"), "one shared copy, not one per device")
    }

    // MARK: - Recently Deleted accounting

    func testDeletionLogPendingFigureRespectsRetention() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deletion-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DeletionLog(directory: directory)
        let now = Date()

        // A fresh commit from today: pending.
        await log.record(assetKeys: (0..<100).map { "photos:fresh\($0)" }, date: now)

        // A commit from 31 days ago: expired.
        await log.record(
            assetKeys: (0..<50).map { "photos:old\($0)" },
            date: now.addingTimeInterval(-31 * 24 * 3600)
        )

        let (count, oldest) = await log.pending(now: now)
        XCTAssertEqual(count, 100, "only the still-recoverable batch counts")
        XCTAssertNotNil(oldest)

        await log.prune(now: now)
        let total = await log.totalDeleted()
        XCTAssertEqual(total, 100, "expired records are purged from disk")
    }

    // MARK: - Fingerprint candidate selection (app boundary)

    func testCandidateSelectionExcludesVideosScreenshotsAndBursts() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var burstMember = AssetRecord(
            key: "photos:burst",
            capturedAt: base,
            burstIdentifier: "burst"
        )
        burstMember.fingerprint = nil
        let records = [
            burstMember,
            AssetRecord(key: "photos:shot", capturedAt: base.addingTimeInterval(1)),
            AssetRecord(key: "photos:screenshot", capturedAt: base.addingTimeInterval(2), isScreenshot: true),
            AssetRecord(key: "photos:clip", capturedAt: base.addingTimeInterval(3), mediaType: .video, duration: 10),
            AssetRecord(
                key: "photos:already-done",
                capturedAt: base.addingTimeInterval(4),
                fingerprint: Fingerprint(revision: 2, cropAndScaleOption: "scaleFill", vector: [0.5])
            ),
        ]

        let candidates = AnalysisCoordinator.candidateRecords(from: records)
        let keys = Set(candidates.map(\.key))
        XCTAssertEqual(keys, ["photos:shot"],
                       "bursts, screenshots, videos and already-printed assets are excluded; only time-adjacent missing prints are candidates")
    }

    // MARK: - Quality pipeline over a real rendered image

    func testQualityAnalyzerClassifiesSolidBlackImage() async throws {
        // A synthetic solid-black CGImage through the app pipeline:
        // render, convert to luma, classify.
        let image = Self.solidImage(value: 0)
        let analyzer = QualityAnalyzer()
        let plane = QualityAnalyzer.lumaPlane(from: image)
        let assessment = FailedFrameDetector().assess(plane)
        XCTAssertEqual(assessment.tier, .obviouslyBroken)
        _ = analyzer
    }

    static func solidImage(value: UInt8, size: Int = 64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4 + 0] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = 255
        }
        return pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }
}
