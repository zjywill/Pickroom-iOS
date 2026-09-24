import XCTest
import Photos
import PickroomCore
@testable import Pickroom

/// App-layer tests over the triage logic: gestures produce the
/// expected decisions; undo restores a whole group in one step;
/// decisions survive a simulated process kill; undeletable assets never
/// enter the candidate set; the commit count matches the pending
/// rejects.
@MainActor
final class DeckModelTests: XCTestCase {
    private var persistence: PersistenceStore!
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        persistence = PersistenceStore(directory: temporaryDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeRecords() -> [AssetRecord] {
        [
            AssetRecord(key: "photos:a", capturedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            AssetRecord(key: "photos:b", capturedAt: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(0.5)),
            AssetRecord(key: "photos:c", capturedAt: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(1.0)),
        ]
    }

    private func burstGroup(flagged: [String]) -> PhotoGroup {
        PhotoGroup(
            id: PhotoGroup.makeID(kind: .burst, memberKeys: ["photos:a", "photos:b", "photos:c"]),
            kind: .burst,
            memberKeys: ["photos:a", "photos:b", "photos:c"],
            representativeKey: "photos:a",
            certainty: 0.8,
            flaggedKeys: flagged,
            suggestedKeeperKey: "photos:a",
            headline: "3 shots"
        )
    }

    func testDiscardAppliesExactlyTheMarkedMembers() async throws {
        let deck = DeckModel(
            groups: [burstGroup(flagged: ["photos:b", "photos:c"])],
            records: makeRecords(),
            persistence: persistence
        )
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b", "photos:c"],
                       "the card pre-marks the app's confident-bad frames")

        deck.discard()
        await deck.settleWrites()

        let decisions = await persistence.loadDecisions()
        XCTAssertEqual(decisions["photos:b"], .reject)
        XCTAssertEqual(decisions["photos:c"], .reject)
        XCTAssertNil(decisions["photos:a"], "the keeper is untouched")
    }

    func testKeepResolvesWithoutRejecting() async throws {
        let deck = DeckModel(
            groups: [burstGroup(flagged: ["photos:b"])],
            records: makeRecords(),
            persistence: persistence
        )
        deck.keep()
        await deck.settleWrites()
        let decisions = await persistence.loadDecisions()
        XCTAssertTrue(decisions.values.allSatisfy { $0 != .reject })
        let states = await persistence.loadGroupStates()
        XCTAssertEqual(states.values.first, .resolved)
    }

    func testUndoRestoresWholeGroupInOneStep() async throws {
        let deck = DeckModel(
            groups: [burstGroup(flagged: ["photos:b", "photos:c"])],
            records: makeRecords(),
            persistence: persistence
        )
        deck.discard()
        await deck.settleWrites()
        XCTAssertTrue(deck.canUndo)

        deck.undo()
        await deck.settleWrites()

        let decisions = deck.decisions
        XCTAssertTrue(decisions.values.allSatisfy { $0 != .reject },
                      "undoing a group restores all of its members at once")
        // The card is back in front, with its marks.
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b", "photos:c"])
    }

    func testToggleMarkChangesWhatDiscardRemoves() async throws {
        let deck = DeckModel(
            groups: [burstGroup(flagged: ["photos:b", "photos:c"])],
            records: makeRecords(),
            persistence: persistence
        )
        // The user vetoes the app's confidence on one frame.
        deck.toggleMark(memberKey: "photos:c")
        deck.discard()
        await deck.settleWrites()

        let decisions = await persistence.loadDecisions()
        XCTAssertEqual(decisions["photos:b"], .reject)
        XCTAssertNil(decisions["photos:c"])
    }

    func testReduceToOneMarksEverythingExceptTheKeeper() async throws {
        let deck = DeckModel(
            groups: [burstGroup(flagged: [])],
            records: makeRecords(),
            persistence: persistence
        )
        deck.reduceToOne(keeperKey: "photos:a")
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b", "photos:c"])

        deck.discard()
        await deck.settleWrites()
        let decisions = await persistence.loadDecisions()
        XCTAssertEqual(decisions["photos:b"], .reject)
        XCTAssertEqual(decisions["photos:c"], .reject)
        XCTAssertNil(decisions["photos:a"])
    }

    func testKeepAllKindNeverDiscards() async throws {
        let bracket = PhotoGroup(
            id: PhotoGroup.makeID(kind: .bracket, memberKeys: ["photos:a", "photos:b"]),
            kind: .bracket,
            memberKeys: ["photos:a", "photos:b"],
            representativeKey: "photos:a",
            certainty: 0.1,
            flaggedKeys: [],
            headline: "Exposure bracket"
        )
        let deck = DeckModel(
            groups: [bracket],
            records: makeRecords(),
            persistence: persistence
        )
        // Even with marks forced on, a bracket resolves as keep.
        deck.reduceToOne(keeperKey: "photos:a")
        deck.discard()
        await deck.settleWrites()

        let decisions = await persistence.loadDecisions()
        XCTAssertTrue(decisions.values.allSatisfy { $0 != .reject },
                      "keep-all kinds never receive a deletion prompt")
    }

    func testProbablyBadCardDiscardsNothingByDefault() async throws {
        let card = PhotoGroup(
            id: PhotoGroup.makeID(kind: .failedFrame, memberKeys: ["photos:b"]),
            kind: .failedFrame,
            memberKeys: ["photos:b"],
            representativeKey: "photos:b",
            certainty: 0.97,
            flaggedKeys: [], // probablyBad: no proposal
            headline: "Probably out of focus"
        )
        let deck = DeckModel(
            groups: [card],
            records: makeRecords(),
            persistence: persistence
        )
        // The single-member swipe left is the user's own call.
        deck.discard()
        await deck.settleWrites()
        let decisions = await persistence.loadDecisions()
        XCTAssertEqual(decisions["photos:b"], .reject,
                       "one swipe left on a single probably-bad photo is the user's decision")
    }

    /// `.iTunesSynced` and `.cloudShared` assets never enter the
    /// candidate set — the release gate.
    func testUndeletableAssetsNeverEnterCandidateSet() async throws {
        var records = makeRecords()
        records[1].contentHash = nil
        let synced = AssetRecord(
            key: "photos:synced",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .iTunesSynced
        )
        let shared = AssetRecord(
            key: "photos:shared",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .cloudShared
        )

        let flagged = PhotoGroup(
            id: PhotoGroup.makeID(kind: .expiredUtility, memberKeys: ["photos:synced", "photos:shared", "photos:a"]),
            kind: .expiredUtility,
            memberKeys: ["photos:synced", "photos:shared", "photos:a"],
            representativeKey: "photos:a",
            certainty: 0.7,
            flaggedKeys: ["photos:synced", "photos:shared", "photos:a"],
            headline: "3 screenshots"
        )

        let deck = DeckModel(
            groups: [flagged],
            records: records + [synced, shared],
            persistence: persistence
        )
        deck.discard()
        await deck.settleWrites()

        XCTAssertEqual(
            deck.pendingRejects,
            ["photos:a"],
            "undeletable and shared assets never enter a delete batch"
        )

        // The candidate filter as a pure function, too.
        let candidates = PhotoKitLibrary.deletionCandidates(
            from: records + [synced, shared],
            decisions: [
                "photos:synced": .reject,
                "photos:shared": .reject,
                "photos:a": .reject,
            ]
        )
        XCTAssertEqual(candidates, ["photos:a"])
    }

    /// The commit sheet's count matches the pending rejects.
    func testCommitCountMatchesPendingRejects() async throws {
        let deck = DeckModel(
            groups: [burstGroup(flagged: ["photos:b", "photos:c"])],
            records: makeRecords(),
            persistence: persistence
        )
        deck.discard()
        await deck.settleWrites()
        XCTAssertEqual(deck.pendingRejects.count, 2)

        // Nothing is deleted during triage: decisions only.
        let decisions = await persistence.loadDecisions()
        XCTAssertEqual(decisions.filter { $0.value == .reject }.count, 2)
    }

    /// The summary on return reports photos reviewed, in the plan's
    /// wording.
    func testSessionSummaryReportsPhotosReviewed() {
        let stored = PersistenceStore.StoredSession(
            currentGroupID: nil,
            reviewedCount: 2,
            reviewedPhotoCount: 412,
            date: Date()
        )
        let summary = DeckModel.sessionSummary(for: stored)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("412 photos reviewed") == true, summary ?? "")

        // Old sessions without the photo count still decode.
        let json = """
        {"currentGroupID":null,"reviewedCount":2,"date":770000000.5}
        """
        let decoded = try! JSONDecoder().decode(
            PersistenceStore.StoredSession.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.reviewedPhotoCount, 0)

        XCTAssertNil(DeckModel.sessionSummary(for: nil))
    }

    /// Killing the app loses nothing: decisions survive a fresh store
    /// over the same directory (a simulated process kill and relaunch).
    func testDecisionsSurviveProcessKillAndRelaunch() async throws {
        let deck1 = DeckModel(
            groups: [burstGroup(flagged: ["photos:b"])],
            records: makeRecords(),
            persistence: persistence
        )
        deck1.discard()
        await deck1.settleWrites()

        // Simulate the process dying and a relaunch with a fresh store.
        let relaunchedStore = PersistenceStore(directory: temporaryDirectory)
        let deck2 = DeckModel(
            groups: [burstGroup(flagged: ["photos:b"])],
            records: makeRecords(),
            decisions: await relaunchedStore.loadDecisions(),
            persistence: relaunchedStore
        )
        XCTAssertEqual(deck2.pendingRejects, ["photos:b"],
                       "decisions survive the relaunch")

        await deck2.restoreSession()
        // The session position survived too — the exact card is gone
        // (resolved), so the deck is finished with it.
        XCTAssertNotEqual(deck2.currentCard?.id, deck1.currentCard?.id)
    }

    func testSessionResumeReturnsToTheExactCard() async throws {
        let group1 = burstGroup(flagged: [])
        var group2 = group1
        group2 = PhotoGroup(
            id: PhotoGroup.makeID(kind: .nearDuplicate, memberKeys: ["photos:a", "photos:b"]),
            kind: .nearDuplicate,
            memberKeys: ["photos:a", "photos:b"],
            representativeKey: "photos:a",
            certainty: 0.5,
            headline: "2 near-identical shots"
        )
        let deck = DeckModel(
            groups: [group1, group2],
            records: makeRecords(),
            persistence: persistence
        )
        // User reviewed the first card and stopped on the second.
        deck.discard()
        await deck.settleWrites()
        XCTAssertEqual(deck.currentCard?.id, group2.id)

        // Kill, relaunch, restore.
        let relaunchedStore = PersistenceStore(directory: temporaryDirectory)
        let relaunched = DeckModel(
            groups: [group1, group2],
            records: makeRecords(),
            decisions: await relaunchedStore.loadDecisions(),
            persistence: relaunchedStore
        )
        await relaunched.restoreSession()
        XCTAssertEqual(relaunched.currentCard?.id, group2.id,
                       "reopening returns to the exact card")
    }

    func testLaterMovesCardToBack() async throws {
        let group1 = burstGroup(flagged: [])
        let group2 = PhotoGroup(
            id: PhotoGroup.makeID(kind: .nearDuplicate, memberKeys: ["photos:a", "photos:b"]),
            kind: .nearDuplicate,
            memberKeys: ["photos:a", "photos:b"],
            representativeKey: "photos:a",
            certainty: 0.5,
            headline: "2 near-identical shots"
        )
        let deck = DeckModel(
            groups: [group1, group2],
            records: makeRecords(),
            persistence: persistence
        )
        XCTAssertEqual(deck.currentCard?.id, group1.id)

        deck.decideLater()
        XCTAssertEqual(deck.currentCard?.id, group2.id, "the next card slid into place")
        XCTAssertEqual(deck.totalCardCount, 2, "the later card still counts as work")

        // Finishing the second card wraps around to the deferred one.
        deck.discard()
        await deck.settleWrites()
        XCTAssertEqual(deck.currentCard?.id, group1.id)
    }

    func testUndoDepthCappedAtConfiguredLimit() async {
        var groups: [PhotoGroup] = []
        for index in 0..<(DeckModel.undoDepth + 10) {
            groups.append(
                PhotoGroup(
                    id: "g\(index)",
                    kind: .failedFrame,
                    memberKeys: ["photos:a"],
                    representativeKey: "photos:a",
                    certainty: 1,
                    flaggedKeys: ["photos:a"],
                    headline: "Broken"
                )
            )
        }
        let deck = DeckModel(
            groups: groups,
            records: makeRecords(),
            persistence: persistence
        )
        for _ in 0..<(DeckModel.undoDepth + 10) {
            deck.discard()
        await deck.settleWrites()
            // Rebuild the deck so every card is reachable in tests.
            if deck.currentCard == nil { break }
        }
        XCTAssertLessThanOrEqual(deck.undoStack.count, DeckModel.undoDepth)
        XCTAssertGreaterThanOrEqual(deck.undoStack.count, DeckModel.undoDepth - 1,
                                    "the plan requires a depth of at least 20")
    }

    // MARK: - Batch decisions (browsers)

    func testBatchMarkSkipsUndeletableAndShowsOnTheCard() async {
        var records = makeRecords()
        records.append(AssetRecord(key: "photos:shared", capturedAt: nil, sourceType: .cloudShared))
        let deck = DeckModel(
            groups: [burstGroup(flagged: [])],
            records: records,
            persistence: persistence
        )
        let snapshot = deck.markForDeletion(keys: ["photos:b", "photos:shared"])
        await deck.settleWrites()

        XCTAssertEqual(deck.pendingRejects, ["photos:b"])
        XCTAssertEqual(snapshot, ["photos:b": .unreviewed])
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b"],
                       "the deck shows the same mark the grid does")
        let stored = await persistence.loadDecisions()
        XCTAssertEqual(stored["photos:b"], .reject)
    }

    func testBatchKeepWithdrawsRejectsAndUndoRestoresThem() async {
        let deck = DeckModel(
            groups: [burstGroup(flagged: ["photos:b", "photos:c"])],
            records: makeRecords(),
            persistence: persistence
        )
        deck.discard()
        XCTAssertEqual(deck.pendingRejects, ["photos:b", "photos:c"])

        let snapshot = deck.keep(keys: ["photos:b", "photos:c", "photos:a"])
        XCTAssertTrue(deck.pendingRejects.isEmpty)
        XCTAssertEqual(snapshot.count, 2, "only the marked items change")

        deck.restore(snapshot)
        await deck.settleWrites()
        XCTAssertEqual(deck.pendingRejects, ["photos:b", "photos:c"])
        let stored = await persistence.loadDecisions()
        XCTAssertEqual(stored["photos:b"], .reject)
    }

    func testBatchMarkReplacesAPickAndRemovePicksClearsOnlyPicks() {
        let deck = DeckModel(
            groups: [burstGroup(flagged: [])],
            records: makeRecords(),
            persistence: persistence
        )
        deck.makeKeeper(memberKey: "photos:a")
        XCTAssertEqual(deck.decisions["photos:a"], .pick)

        deck.removePicks(keys: ["photos:a", "photos:b"])
        XCTAssertNil(deck.decisions["photos:a"])

        deck.makeKeeper(memberKey: "photos:a")
        deck.markForDeletion(keys: ["photos:a"])
        XCTAssertEqual(deck.decisions["photos:a"], .reject, "the latest explicit gesture wins")
    }

    // MARK: - Set detail: best shot

    func testKeepOnlyPicksTheBestAndMarksTheRestSparingFavourites() {
        var records = makeRecords()
        records[2] = AssetRecord(key: "photos:c", capturedAt: records[2].capturedAt, isFavorite: true)
        let members = ["photos:a", "photos:b", "photos:c"]
        let deck = DeckModel(groups: [burstGroup(flagged: [])], records: records, persistence: persistence)

        deck.setKeeper("photos:b", among: members)
        XCTAssertEqual(deck.decisions["photos:b"], .pick)

        let snapshot = deck.keepOnly("photos:a", among: members)
        XCTAssertEqual(deck.decisions["photos:a"], .pick)
        XCTAssertEqual(deck.decisions["photos:b"], .reject, "the old pick is tossed with the rest")
        XCTAssertNil(deck.decisions["photos:c"], "a favourite is never tossed by the bulk button")
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b"])

        deck.restore(snapshot)
        XCTAssertEqual(deck.decisions["photos:b"], .pick)
        XCTAssertNil(deck.decisions["photos:a"])
    }

    // MARK: - Set page: Next set

    func testNextSetRejectsExactlyTheMarksOnScreen() async {
        let deck = DeckModel(groups: [burstGroup(flagged: ["photos:b"])], records: makeRecords(), persistence: persistence)
        deck.toggleMark(memberKey: "photos:c")
        deck.toggleMark(memberKey: "photos:b")   // the user keeps the pre-marked one
        deck.resolveCurrent()
        await deck.settleWrites()

        XCTAssertEqual(deck.pendingRejects, ["photos:c"])
        XCTAssertTrue(deck.isFinished)
        deck.undo()
        XCTAssertTrue(deck.pendingRejects.isEmpty, "Back brings the set back undecided")
        XCTAssertNotNil(deck.currentCard)
    }

    func testNextSetWithNoMarksKeepsASinglePhoto() {
        let group = PhotoGroup(
            id: "single", kind: .failedFrame, memberKeys: ["photos:a"], representativeKey: "photos:a",
            certainty: 1, flaggedKeys: [], suggestedKeeperKey: nil, headline: "1"
        )
        let deck = DeckModel(groups: [group], records: makeRecords(), persistence: persistence)
        deck.resolveCurrent()
        XCTAssertTrue(deck.pendingRejects.isEmpty, "unlike a left swipe, Next never tosses an unmarked photo")
    }

    func testEarlierRejectsShowAsMarksOnTheSet() {
        let deck = DeckModel(
            groups: [burstGroup(flagged: [])],
            records: makeRecords(),
            decisions: ["photos:c": .reject],
            persistence: persistence
        )
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:c"])
        deck.setMarks([])
        deck.resolveCurrent()
        XCTAssertTrue(deck.pendingRejects.isEmpty, "unmarking on the page withdraws the earlier reject")
    }

    // MARK: - Keep-one default

    func testSimilarSetDefaultsToKeepTheBestAndMarkTheRest() async {
        var records = makeRecords()
        records.append(AssetRecord(key: "photos:fav", capturedAt: nil, isFavorite: true))
        let keys = ["photos:a", "photos:b", "photos:c", "photos:fav"]
        let group = PhotoGroup(
            id: "burst", kind: .burst, memberKeys: keys, representativeKey: "photos:a",
            certainty: 0.8, flaggedKeys: [], suggestedKeeperKey: "photos:b", headline: "4 shots"
        )
        let deck = DeckModel(groups: [group], records: records, persistence: persistence)
        await deck.rankCurrentCard()
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:a", "photos:c"],
                       "the keeper and the favourite stay; the rest are marked")

        // Choosing another best before editing: the proposal follows it.
        deck.makeKeeper(memberKey: "photos:c")
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:a", "photos:b"])

        // Once edited, the default never comes back.
        deck.toggleMark(memberKey: "photos:a")
        await deck.rankCurrentCard()
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:b"])
    }

    func testScreenshotBucketsGetNoKeepOneDefault() async {
        let group = PhotoGroup(
            id: "shots", kind: .expiredUtility, memberKeys: ["photos:a", "photos:b"], representativeKey: "photos:a",
            certainty: 0.5, flaggedKeys: [], suggestedKeeperKey: nil, headline: "2 screenshots"
        )
        let deck = DeckModel(groups: [group], records: makeRecords(), persistence: persistence)
        await deck.rankCurrentCard()
        XCTAssertEqual(deck.currentCard?.markedKeys, [])
    }

    // MARK: - One photo at a time

    func testSwipingEachPhotoResolvesTheSetWithExactlyThoseChoices() async {
        let other = PhotoGroup(
            id: "other", kind: .expiredUtility, memberKeys: ["photos:c"], representativeKey: "photos:c",
            certainty: 0.5, flaggedKeys: [], suggestedKeeperKey: nil, headline: "1 screenshot"
        )
        let pair = PhotoGroup(
            id: "pair", kind: .burst, memberKeys: ["photos:a", "photos:b"], representativeKey: "photos:a",
            certainty: 0.8, flaggedKeys: [], suggestedKeeperKey: "photos:b", headline: "2 shots"
        )
        let deck = DeckModel(groups: [pair, other], records: makeRecords(), persistence: persistence)
        await deck.rankCurrentCard()

        XCTAssertEqual(deck.memberOrder, ["photos:b", "photos:a"], "the keeper is judged first")
        XCTAssertEqual(deck.currentMemberKey, "photos:b")

        // Toss the suggested keeper, keep the one the app proposed tossing.
        deck.swipeMember(discard: true)
        XCTAssertEqual(deck.currentCard?.id, "pair", "the set stays up until its last photo")
        XCTAssertEqual(deck.currentMemberKey, "photos:a")
        deck.swipeMember(discard: false)

        XCTAssertEqual(deck.currentCard?.id, "other", "the last photo brings up the next set")
        XCTAssertEqual(deck.memberPosition, 0)
        XCTAssertEqual(deck.decisions["photos:b"], .reject)
        XCTAssertNil(deck.decisions["photos:a"])
        await deck.settleWrites()
        let states = await persistence.loadGroupStates()
        XCTAssertEqual(states["pair"], .resolved)
    }

    func testBackUndoesOneSwipeAtATimeAcrossSets() async {
        let first = PhotoGroup(
            id: "first", kind: .expiredUtility, memberKeys: ["photos:a", "photos:b"], representativeKey: "photos:a",
            certainty: 0.5, flaggedKeys: [], suggestedKeeperKey: nil, headline: "2 screenshots"
        )
        let second = PhotoGroup(
            id: "second", kind: .expiredUtility, memberKeys: ["photos:c"], representativeKey: "photos:c",
            certainty: 0.5, flaggedKeys: [], suggestedKeeperKey: nil, headline: "1 screenshot"
        )
        let deck = DeckModel(groups: [first, second], records: makeRecords(), persistence: persistence)
        XCTAssertFalse(deck.canGoBack)

        deck.swipeMember(discard: true)   // a: toss
        XCTAssertTrue(deck.canGoBack)
        deck.back()
        XCTAssertEqual(deck.currentMemberKey, "photos:a")
        XCTAssertEqual(deck.currentCard?.markedKeys, [], "back puts the mark back as it was")

        deck.swipeMember(discard: true)   // a: toss
        deck.swipeMember(discard: false)  // b: keep → resolves
        XCTAssertEqual(deck.currentCard?.id, "second")
        XCTAssertEqual(deck.decisions["photos:a"], .reject)

        // From the next set's first photo, back lands on the last photo
        // of the set before — undecided, with the earlier swipe intact.
        deck.back()
        XCTAssertEqual(deck.currentCard?.id, "first")
        XCTAssertEqual(deck.memberPosition, 1)
        XCTAssertEqual(deck.currentMemberKey, "photos:b")
        XCTAssertEqual(deck.currentCard?.markedKeys, ["photos:a"])
        XCTAssertNil(deck.decisions["photos:a"], "the set is pending again until it resolves")

        deck.swipeMember(discard: true)   // b: toss this time
        XCTAssertEqual(deck.currentCard?.id, "second")
        XCTAssertEqual(deck.decisions["photos:a"], .reject)
        XCTAssertEqual(deck.decisions["photos:b"], .reject)
    }

    func testSwipingLeftOnAPickWithdrawsItAndBackRestoresIt() async {
        let group = PhotoGroup(
            id: "pair", kind: .burst, memberKeys: ["photos:a", "photos:b"], representativeKey: "photos:a",
            certainty: 0.8, flaggedKeys: [], suggestedKeeperKey: nil, headline: "2 shots"
        )
        let deck = DeckModel(groups: [group], records: makeRecords(), persistence: persistence)
        deck.makeKeeper(memberKey: "photos:b")
        XCTAssertEqual(deck.currentMemberKey, "photos:b")

        deck.swipeMember(discard: true)
        XCTAssertNil(deck.decisions["photos:b"])
        deck.back()
        XCTAssertEqual(deck.decisions["photos:b"], .pick)
    }

    func testLaterRestartsTheSetsWalk() {
        let group = PhotoGroup(
            id: "shots", kind: .expiredUtility, memberKeys: ["photos:a", "photos:b"], representativeKey: "photos:a",
            certainty: 0.5, flaggedKeys: [], suggestedKeeperKey: nil, headline: "2 screenshots"
        )
        let deck = DeckModel(groups: [group], records: makeRecords(), persistence: persistence)
        deck.swipeMember(discard: false)
        deck.decideLater()
        XCTAssertEqual(deck.currentCard?.id, "shots", "the only set comes straight back")
        XCTAssertEqual(deck.memberPosition, 0)
    }
}
