import XCTest
@testable import PickroomCore

/// The cross-year case, written first because the whole time-first
/// design exists for it: two assets with identical fingerprints 365 days
/// apart produce **no** near-duplicate group. A selfie this year and one
/// next year are two photographs the user wants to keep, however alike
/// they look in pixels.
final class CrossYearTests: XCTestCase {
    func testIdenticalFingerprintsOneYearApartNeverGroup() async throws {
        let identical = Fixtures.print([0.1, 0.2, 0.3, 0.4])
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, fingerprint: identical),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(365 * 24 * 3600), fingerprint: identical),
        ]

        let engine = GroupEngine()
        let (groups, _) = engine.makeGroups(assets: assets)

        let nearDuplicates = groups.filter { $0.kind == .nearDuplicate }
        XCTAssertTrue(nearDuplicates.isEmpty, "Assets a year apart must never form a near-duplicate group, got: \(nearDuplicates.map(\.headline))")
    }

    func testIdenticalFingerprintsAcrossYearsWithHashStillGroupAsExactDuplicatesOnly() throws {
        // Exact duplicates are the sole exception to time-first: the
        // same file is the same file regardless of when it was taken.
        let hash = Data([0x01, 0x02, 0x03])
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, fingerprint: Fixtures.print([0.1]), contentHash: hash),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(400 * 24 * 3600), fingerprint: Fixtures.print([0.1]), contentHash: hash),
        ]

        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertEqual(groups.filter { $0.kind == .nearDuplicate }.count, 0)
        let exact = try XCTUnwrap(groups.first { $0.kind == .exactDuplicate })
        XCTAssertEqual(Set(exact.memberKeys), ["a", "b"])
    }
}

/// Time clustering: the boundary conditions the session logic must
/// honour.
final class TimeClusteringTests: XCTestCase {
    func testGapExactlyAtThresholdStaysOneSession() {
        let gap: TimeInterval = 4 * 3600
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(gap)),
        ]
        let pairs = CandidateSelection.candidatePairs(
            assets, sessionGap: gap, window: gap
        )
        // A gap of exactly sessionGap is still the same session — only a
        // strictly greater gap splits.
        XCTAssertFalse(pairs.isEmpty)
    }

    func testGapBeyondThresholdSplitsSession() {
        let gap: TimeInterval = 4 * 3600 + 1
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(gap)),
        ]
        let pairs = CandidateSelection.candidatePairs(
            assets, sessionGap: 4 * 3600, window: 4 * 3600
        )
        XCTAssertTrue(pairs.isEmpty)
    }

    func testSessionCrossingMidnightStaysOneSession() {
        // 23:50 local to 00:10 next day: no calendar boundary is ever
        // consulted, so a night shoot is one session.
        let lateNight = date(2023, 11, 14, 23, 50)
        let afterMidnight = date(2023, 11, 15, 0, 10)
        let assets = [
            Fixtures.asset("a", capturedAt: lateNight),
            Fixtures.asset("b", capturedAt: afterMidnight),
        ]
        let pairs = CandidateSelection.candidatePairs(assets, sessionGap: 4 * 3600, window: 3600)
        XCTAssertEqual(pairs.count, 1)
    }

    func testTimezoneJumpDoesNotSplitSession() {
        // Clustering runs on absolute timestamps. A timezone change
        // while travelling does not move a Date, so the session holds.
        let tokyo = Fixtures.base
        let fifteenMinutesLater = tokyo.addingTimeInterval(15 * 60)
        let assets = [
            Fixtures.asset("a", capturedAt: tokyo),
            Fixtures.asset("b", capturedAt: fifteenMinutesLater),
        ]
        let pairs = CandidateSelection.candidatePairs(assets, sessionGap: 4 * 3600, window: 3600)
        XCTAssertEqual(pairs.count, 1)
    }

    func testDegenerateTimestampsFallBackToIdentifierOrderAndJoinNoGroup() throws {
        // A camera with an unset clock produces thousands of assets at
        // 2000-01-01. Such assets take part in exact-duplicate detection
        // only, and order by identifier.
        let epochZero = Date(timeIntervalSince1970: 0)
        let identical = Fixtures.print([0.9, 0.8, 0.7])
        let hash = Data([1, 1, 1])
        let assets = [
            Fixtures.asset("z", capturedAt: epochZero, fingerprint: identical, contentHash: hash),
            Fixtures.asset("y", capturedAt: epochZero, fingerprint: identical, contentHash: hash),
            Fixtures.asset("x", capturedAt: epochZero, fingerprint: identical, contentHash: hash),
        ]

        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertTrue(groups.filter { $0.kind == .nearDuplicate }.isEmpty)
        // They are still ordered by key wherever order matters (the
        // engine's deterministic member order is x, y, z).
        let exact = try XCTUnwrap(groups.first { $0.kind == .exactDuplicate }, "Unknown-date assets still group as exact duplicates when the hash matches")
        XCTAssertEqual(exact.memberKeys, ["x", "y", "z"])
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: components)!
    }
}

/// The floating threshold: the same fingerprint distance groups at 2 s
/// and does not at 2 h.
final class FloatingThresholdTests: XCTestCase {
    private let distance = 0.4 // under the loose 0.45, over the strict 0.25

    func testSameDistanceGroupsAtTwoSeconds() {
        let a = Fixtures.print([0.0])
        let b = Fixtures.print([Float(distance)])
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, fingerprint: a),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(2), fingerprint: b),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertEqual(groups.filter { $0.kind == .nearDuplicate }.count, 1)
    }

    func testSameDistanceDoesNotGroupAtTwoHours() {
        let a = Fixtures.print([0.0])
        let b = Fixtures.print([Float(distance)])
        let assets = [
            Fixtures.asset("a", capturedAt: Fixtures.base, fingerprint: a),
            Fixtures.asset("b", capturedAt: Fixtures.base.addingTimeInterval(2 * 3600), fingerprint: b),
        ]
        let (groups, _) = GroupEngine().makeGroups(assets: assets)
        XCTAssertTrue(groups.filter { $0.kind == .nearDuplicate }.isEmpty)
    }

    func testTableShape() {
        let table = NearDuplicateThresholds()
        XCTAssertEqual(table.threshold(forGap: 0), table.burst)
        XCTAssertEqual(table.threshold(forGap: 2.9), table.burst)
        XCTAssertEqual(table.threshold(forGap: 3), table.retried)
        XCTAssertEqual(table.threshold(forGap: 119), table.retried)
        XCTAssertEqual(table.threshold(forGap: 120), table.sameActivity)
        XCTAssertEqual(table.threshold(forGap: 3599), table.sameActivity)
        XCTAssertNil(table.threshold(forGap: 3600), "past one hour, not a candidate at all")
        XCTAssertNil(table.threshold(forGap: 24 * 3600))
        XCTAssertFalse(table.isPairGroupable(gap: 24 * 3600), "never grouped past 24 h, whatever the distance")
    }
}

/// The revision guard: a cached fingerprint recorded under a different
/// request revision or crop-and-scale option is discarded and
/// recomputed, never compared.
final class RevisionGuardTests: XCTestCase {
    func testStaleRevisionEntriesAreNeverReturned() {
        var cache = FingerprintCache(
            parameters: FingerprintRequestParameters(revision: 2, cropAndScaleOption: "scaleFill")
        )
        cache.upsert(
            .init(
                key: "photos:old",
                modificationDate: Fixtures.base,
                fingerprint: Fixtures.print([0.5], revision: 1, option: "scaleFill")
            )
        )
        cache.upsert(
            .init(
                key: "photos:wrongCrop",
                modificationDate: Fixtures.base,
                fingerprint: Fixtures.print([0.5], revision: 2, option: "centerCrop")
            )
        )
        cache.upsert(
            .init(
                key: "photos:fresh",
                modificationDate: Fixtures.base,
                fingerprint: Fixtures.print([0.5], revision: 2, option: "scaleFill")
            )
        )

        XCTAssertNil(cache.fingerprint(forKey: "photos:old", modificationDate: Fixtures.base))
        XCTAssertNil(cache.fingerprint(forKey: "photos:wrongCrop", modificationDate: Fixtures.base))
        XCTAssertEqual(
            cache.fingerprint(forKey: "photos:fresh", modificationDate: Fixtures.base)?.vector,
            [0.5]
        )
        XCTAssertEqual(Set(cache.staleKeys()), ["photos:old", "photos:wrongCrop"])
    }

    func testModifiedAssetsInvalidateEntries() {
        var cache = FingerprintCache(
            parameters: FingerprintRequestParameters(revision: 2, cropAndScaleOption: "scaleFill")
        )
        cache.upsert(
            .init(
                key: "photos:a",
                modificationDate: Fixtures.base,
                fingerprint: Fixtures.print([0.5])
            )
        )
        XCTAssertNil(
            cache.fingerprint(forKey: "photos:a", modificationDate: Fixtures.base.addingTimeInterval(60))
        )
    }

    func testBinaryRoundTripSurvivesLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pickroom-fingerprint-cache-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        var cache = FingerprintCache(
            parameters: FingerprintRequestParameters(revision: 2, cropAndScaleOption: "scaleFill")
        )
        let vector: [Float] = (0..<32).map { Float($0) / 32 }
        cache.upsert(
            .init(
                key: "photos:abc",
                modificationDate: Fixtures.base,
                fingerprint: Fingerprint(revision: 2, cropAndScaleOption: "scaleFill", vector: vector)
            )
        )
        cache.upsert(
            .init(
                key: "photos:xyz",
                modificationDate: nil,
                fingerprint: Fingerprint(revision: 1, cropAndScaleOption: "scaleFill", vector: [1])
            )
        )
        try cache.save(to: url)

        let reloaded = FingerprintCache.load(
            from: url,
            parameters: FingerprintRequestParameters(revision: 2, cropAndScaleOption: "scaleFill")
        )
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(
            reloaded.fingerprint(forKey: "photos:abc", modificationDate: Fixtures.base)?.vector,
            vector
        )
        XCTAssertEqual(reloaded.staleKeys(), ["photos:xyz"])
    }

    func testIncomparablePrintsReturnNoDistance() {
        let a = Fixtures.print([0.1], revision: 1, option: "scaleFill")
        let b = Fixtures.print([0.1], revision: 2, option: "scaleFill")
        let c = Fixtures.print([0.1], revision: 2, option: "centerCrop")
        let metric = EuclideanFeaturePrintMetric()
        XCTAssertNil(metric.distance(a, b))
        XCTAssertNil(metric.distance(b, c))
        let sameOption = Fixtures.print([0.3], revision: 2, option: "scaleFill")
        XCTAssertEqual(try XCTUnwrap(metric.distance(b, sameOption)), 0.2, accuracy: 1e-6)
    }
}
