import XCTest
import PickroomCore
@testable import Pickroom

/// Regression tests for the implementation review: the user's keeper is
/// never deleted, undo survives an engine reload, deletions can be
/// withdrawn after a relaunch, and analysis never resurrects assets.
@MainActor
final class ReviewFixTests: XCTestCase {
    private var directory: URL!
    private var persistence: PersistenceStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        persistence = PersistenceStore(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func records(_ keys: [String]) -> [AssetRecord] {
        keys.enumerated().map { index, key in
            AssetRecord(key: key, capturedAt: base.addingTimeInterval(Double(index)))
        }
    }

    private func group(_ keys: [String], flagged: [String] = [], suggested: String? = nil) -> PhotoGroup {
        PhotoGroup(
            id: PhotoGroup.makeID(kind: .burst, memberKeys: keys),
            kind: .burst,
            memberKeys: keys,
            representativeKey: keys[0],
            certainty: 0.8,
            flaggedKeys: flagged,
            suggestedKeeperKey: suggested,
            headline: "\(keys.count) shots"
        )
    }

    // MARK: - The user's keeper

    func testReduceToOneKeepsTheUsersPickNotTheSuggestion() async {
        let keys = ["photos:a", "photos:b", "photos:c"]
        let deck = DeckModel(
            groups: [group(keys, suggested: "photos:a")],
            records: records(keys),
            persistence: persistence
        )
        deck.makeKeeper(memberKey: "photos:b")
        XCTAssertEqual(deck.keeperKey(for: deck.currentCard!), "photos:b")

        deck.reduceToOne()
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:a", "photos:c"])

        deck.discard()
        await deck.settleWrites()
        let stored = await persistence.loadDecisions()
        XCTAssertEqual(stored["photos:b"], .pick, "the user's keeper survives the swipe")
        XCTAssertEqual(stored["photos:a"], .reject)
    }

    func testMakeKeeperUnmarksAFlaggedFrame() {
        let keys = ["photos:a", "photos:b"]
        let deck = DeckModel(
            groups: [group(keys, flagged: ["photos:b"])],
            records: records(keys),
            persistence: persistence
        )
        deck.makeKeeper(memberKey: "photos:b")
        XCTAssertFalse(deck.currentCard?.markedKeys.contains("photos:b") == true, "the new keeper is unmarked")
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:a"], "keep-one default: the rest is marked")
    }

    func testPickFromEarlierSessionIsNeverPreMarked() {
        let keys = ["photos:a", "photos:b"]
        let deck = DeckModel(
            groups: [group(keys, flagged: ["photos:a", "photos:b"])],
            records: records(keys),
            decisions: ["photos:b": .pick],
            persistence: persistence
        )
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:a"])
    }

    func testMarkingThePickWithdrawsIt() async {
        let keys = ["photos:a", "photos:b"]
        let deck = DeckModel(
            groups: [group(keys)],
            records: records(keys),
            persistence: persistence
        )
        deck.makeKeeper(memberKey: "photos:b")
        deck.toggleMark(memberKey: "photos:b")
        XCTAssertNil(deck.decisions["photos:b"], "the latest explicit gesture wins")
        deck.discard()
        await deck.settleWrites()
        XCTAssertEqual(deck.decisions["photos:b"], .reject)
    }

    func testOnlyOneKeeperPerGroup() {
        let keys = ["photos:a", "photos:b"]
        let deck = DeckModel(groups: [group(keys)], records: records(keys), persistence: persistence)
        deck.makeKeeper(memberKey: "photos:a")
        deck.makeKeeper(memberKey: "photos:b")
        XCTAssertNil(deck.decisions["photos:a"])
        XCTAssertEqual(deck.decisions["photos:b"], .pick)
    }

    // MARK: - Undo and reload

    func testUndoBringsTheCardBackAfterAnEngineReload() async {
        let keys = ["photos:a", "photos:b", "photos:c"]
        let first = group(["photos:a", "photos:b"], flagged: ["photos:b"])
        let second = PhotoGroup(
            id: "second", kind: .failedFrame, memberKeys: ["photos:c"],
            representativeKey: "photos:c", certainty: 1, headline: "Broken"
        )
        let deck = DeckModel(groups: [first, second], records: records(keys), persistence: persistence)

        deck.discard()
        XCTAssertEqual(deck.currentCard?.id, "second")
        // The engine re-runs (analysis finished) while the card is
        // resolved — it no longer appears among the pending groups.
        var resolved = first
        resolved.state = .resolved
        deck.reload(groups: [resolved, second], records: records(keys))
        XCTAssertEqual(deck.currentCard?.id, "second")

        deck.undo()
        XCTAssertEqual(deck.currentCard?.id, first.id, "undo puts the card back in front")
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b"])
        XCTAssertNil(deck.decisions["photos:b"])

        deck.keep()
        XCTAssertEqual(deck.currentCard?.id, "second", "and the deck continues where it was")
    }

    func testReloadKeepsLaterPileAndMarkEdits() {
        let keys = ["photos:a", "photos:b", "photos:c"]
        let first = group(["photos:a", "photos:b"], flagged: ["photos:b"])
        let second = PhotoGroup(
            id: "second", kind: .failedFrame, memberKeys: ["photos:c"],
            representativeKey: "photos:c", certainty: 1, headline: "Broken"
        )
        let deck = DeckModel(groups: [first, second], records: records(keys), persistence: persistence)
        deck.toggleMark(memberKey: "photos:b") // user vetoes the flag
        deck.decideLater()
        XCTAssertEqual(deck.currentCard?.id, "second")

        deck.reload(groups: [first, second], records: records(keys))
        XCTAssertEqual(deck.currentCard?.id, "second")
        XCTAssertEqual(deck.laterQueue.map(\.id), [first.id], "the later pile survives a reload")
        XCTAssertEqual(deck.laterQueue.first?.markedKeys, [], "so does the user's veto")
    }

    // MARK: - Withdrawing a deletion

    func testUnmarkWithdrawsARejectAfterRelaunch() async {
        let keys = ["photos:a", "photos:b"]
        let deck = DeckModel(
            groups: [group(keys, flagged: ["photos:b"])],
            records: records(keys),
            persistence: persistence
        )
        deck.discard()
        await deck.settleWrites()

        let relaunchedStore = PersistenceStore(directory: directory)
        let relaunched = DeckModel(
            groups: [],
            records: records(keys),
            decisions: await relaunchedStore.loadDecisions(),
            persistence: relaunchedStore
        )
        XCTAssertEqual(relaunched.pendingRejects, ["photos:b"])
        XCTAssertFalse(relaunched.canUndo, "undo history does not survive a relaunch")

        relaunched.unmark(key: "photos:b")
        await relaunched.settleWrites()
        XCTAssertTrue(relaunched.pendingRejects.isEmpty)
        let stored = await PersistenceStore(directory: directory).loadDecisions()
        XCTAssertNil(stored["photos:b"])
    }

    // MARK: - Persistence journal

    func testJournalSurvivesRelaunchAndCompaction() async {
        for index in 0..<(PersistenceStore.journalCompactionThreshold + 10) {
            await persistence.saveDecision(key: "photos:\(index)", decision: .reject)
        }
        await persistence.removeDecisions(keys: ["photos:0"])
        await persistence.saveDecision(key: "photos:1", decision: .pick)

        let reloaded = await PersistenceStore(directory: directory).loadDecisions()
        XCTAssertEqual(reloaded.count, PersistenceStore.journalCompactionThreshold + 9)
        XCTAssertNil(reloaded["photos:0"])
        XCTAssertEqual(reloaded["photos:1"], .pick)
        XCTAssertEqual(reloaded["photos:2"], .reject)
    }

    func testTornJournalEntryIsIgnored() async throws {
        await persistence.saveDecision(key: "photos:kept", decision: .reject)
        let journal = directory.appendingPathComponent("decisions.journal")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9, 0, 0, 0, 0x70])) // killed mid-write
        try handle.close()

        let reloaded = await PersistenceStore(directory: directory).loadDecisions()
        XCTAssertEqual(reloaded, ["photos:kept": .reject])
    }

    // MARK: - Analysis merge

    func testAnalysisNeverResurrectsDeletedAssets() {
        let before = records(["photos:a", "photos:b"])
        var analysed = before
        analysed[1].contentHash = Data([1])
        analysed[0].contentHash = Data([2])
        // The library changed while analysis ran: b was deleted.
        let current = records(["photos:a"])

        let merged = AppModel.merge(analysis: analysed, into: current)
        XCTAssertEqual(merged.map(\.key), ["photos:a"])
        XCTAssertEqual(merged[0].contentHash, Data([2]))
    }

    func testAnalysisOfAnEditedAssetIsDiscarded() {
        let current = [AssetRecord(key: "photos:a", capturedAt: base, modificationDate: base.addingTimeInterval(60))]
        var stale = AssetRecord(key: "photos:a", capturedAt: base, modificationDate: base)
        stale.contentHash = Data([3])
        let merged = AppModel.merge(analysis: [stale], into: current)
        XCTAssertNil(merged[0].contentHash)
    }

    // MARK: - Guard candidates

    func testBracketCandidatesAreCloseInTimeOnly() {
        let assets = [
            AssetRecord(key: "photos:a", capturedAt: base),
            AssetRecord(key: "photos:b", capturedAt: base.addingTimeInterval(1)),
            AssetRecord(key: "photos:far", capturedAt: base.addingTimeInterval(600)),
            AssetRecord(key: "photos:shot", capturedAt: base.addingTimeInterval(601), isScreenshot: true),
        ]
        let keys = AnalysisCoordinator.bracketCandidateKeys(assets, configuration: GroupEngineConfiguration())
        XCTAssertEqual(keys, ["photos:a", "photos:b"])
    }
}

/// Triage's "Start over": decisions and decided sets are cleared; ignored
/// sets stay ignored unless asked.
final class StartOverTests: XCTestCase {
    func testStartOverClearsDecisionsAndDecidedSets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-over-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        await store.saveDecisions(["photos:a": .reject, "photos:b": .pick])
        await store.saveGroupState(id: "done", state: .resolved)
        await store.saveGroupState(id: "ignored", state: .dismissed)

        await store.startOver(includingIgnored: false)
        let relaunched = PersistenceStore(directory: directory)
        let decisions = await relaunched.loadDecisions()
        let states = await relaunched.loadGroupStates()
        let session = await relaunched.loadSession()
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertEqual(states, ["ignored": .dismissed])
        XCTAssertNil(session)

        await relaunched.startOver(includingIgnored: true)
        let cleared = await relaunched.loadGroupStates()
        XCTAssertTrue(cleared.isEmpty)
    }
}
