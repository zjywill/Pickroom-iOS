import Foundation
import Photos
import UIKit
import Observation
import PickroomCore

/// One card in the deck: a group, the per-member marks currently on
/// it, and (once ranked near this position) the best-shot suggestion
/// with its visible reason.
struct CardModel: Identifiable, Hashable {
    var group: PhotoGroup
    /// Members currently marked for removal, shown in the thumbnail
    /// strip. Pre-marked from `group.flaggedKeys` — the frames the app
    /// is confident about — and adjustable before the swipe.
    var markedKeys: Set<String>
    /// Best-shot suggestion, with its plain-language reason.
    var suggestion: ShotScore?

    var id: String { group.id }
}

/// The deck: group-aware swipe triage. One card at a time, one gesture
/// per decision, and one decision resolves a whole set of
/// near-identical shots.
///
/// Semantics (§5):
/// - swipe right — keep (resolve; nothing from this card is deleted)
/// - swipe left — discard **exactly the marked members** (the app's
///   confident-bad frames by default)
/// - swipe up — decide later (card goes to the back of the deck)
/// - tap — inspect larger; long press — the whole group
///
/// Keep-all kinds (bracket, versions) never propose anything: swipe
/// left resolves them as keep, because there is nothing they are
/// allowed to discard.
@MainActor
@Observable
final class DeckModel {
    /// Undo history depth. The plan requires at least 20.
    static let undoDepth = 100

    struct UndoEntry {
        let groupID: String
        /// The card as it was before the swipe, so undo can put it back
        /// even after an engine reload dropped it from the deck.
        let card: CardModel
        let applied: [String: PhotoDecision]
        let previous: [String: PhotoDecision]
        let previousMarks: Set<String>
        let wasResolved: GroupState
    }

    private(set) var cards: [CardModel]
    private(set) var laterQueue: [CardModel]
    private(set) var currentIndex: Int
    private(set) var undoStack: [UndoEntry] = []

    private var records: [String: AssetRecord]
    private let persistence: PersistenceStore
    private let ranker: any ShotRanker

    /// Decisions made during this session (and loaded from previous
    /// ones): key → decision, persisted immediately.
    private(set) var decisions: [String: PhotoDecision]
    private(set) var reviewedGroupCount = 0
    private(set) var reviewedPhotoCount = 0

    var hapticsEnabled = true

    init(
        groups: [PhotoGroup],
        records: [AssetRecord],
        decisions: [String: PhotoDecision] = [:],
        ranker: any ShotRanker = FallbackShotRanker(),
        persistence: PersistenceStore
    ) {
        // The deck serves pending groups, ordered by certainty —
        // cheapest decision first. Resolved and dismissed groups from
        // previous sessions are skipped.
        self.cards = groups
            .filter { $0.state == .pending }
            .map { CardModel(group: $0, markedKeys: Self.initialMarks($0, decisions: decisions)) }
        self.laterQueue = []
        self.currentIndex = 0
        self.records = Dictionary(
            uniqueKeysWithValues: records.map { ($0.key, $0) }
        )
        self.decisions = decisions
        self.ranker = ranker
        self.persistence = persistence
        self.session = nil
        reviewedPhotoCount = decisions.values.filter(\.isReviewed).count
    }

    /// Restores the exact card the user was on. "Killing the app loses
    /// nothing" — every decision persisted immediately, the position
    /// with it.
    func restoreSession() async {
        guard let stored = await persistence.loadSession() else { return }
        session = stored
        if let groupID = stored.currentGroupID,
           let index = cards.firstIndex(where: { $0.id == groupID }) {
            currentIndex = index
        }
        reviewedGroupCount = min(stored.reviewedCount, cards.count)
    }

    /// Summary shown on return: "Last time: 412 photos reviewed."
    static func sessionSummary(for stored: PersistenceStore.StoredSession?) -> String? {
        guard let stored else { return nil }
        let formatter = RelativeDateTimeFormatter()
        let when = formatter.localizedString(for: stored.date, relativeTo: Date())
        let noun = stored.reviewedPhotoCount == 1 ? "photo" : "photos"
        return "Last time: \(stored.reviewedPhotoCount.formatted()) \(noun) reviewed, \(when)."
    }

    private var session: PersistenceStore.StoredSession?

    // MARK: - Current card

    var currentCard: CardModel? {
        let all = cards + laterQueue
        guard currentIndex >= 0, currentIndex < all.count else { return nil }
        return all[currentIndex]
    }

    var totalCardCount: Int { cards.count + laterQueue.count }

    var remainingCardCount: Int {
        totalCardCount - currentIndex
    }

    /// Progress in work remaining — "340 of 1,200 sets reviewed" —
    /// never in gigabytes.
    var progressText: String {
        "\(reviewedGroupCount) of \(totalCardCount) sets reviewed"
    }

    var isFinished: Bool { currentCard == nil }

    // MARK: - Gestures

    /// Swipe right — keep. Resolves the card; no member is deleted.
    func keep() {
        applySwipe(.keep)
    }

    /// Swipe left — discard the marked members. On keep-all kinds
    /// (bracket, versions) and on cards whose marks were all cleared,
    /// this resolves as keep: those cards have nothing they are allowed
    /// to propose.
    func discard() {
        applySwipe(.discard)
    }

    /// Swipe up — decide later. The card moves to the back of the deck;
    /// the next card slides into place.
    func decideLater() {
        guard let card = currentCard else { return }
        commitHaptic()
        if currentIndex < cards.count {
            cards.remove(at: currentIndex)
        } else {
            laterQueue.remove(at: currentIndex - cards.count)
        }
        laterQueue.append(card)
        persistSession()
    }

    /// Toggles a member's mark in the thumbnail strip. The user can
    /// veto the app's confident frames or add their own before
    /// deciding. Marking the user's own keeper withdraws the pick —
    /// the latest explicit gesture wins, and a pick is never silently
    /// deleted.
    func toggleMark(memberKey: String) {
        guard
            var card = currentCard,
            card.group.memberKeys.contains(memberKey)
        else { return }
        if card.markedKeys.contains(memberKey) {
            card.markedKeys.remove(memberKey)
        } else {
            card.markedKeys.insert(memberKey)
            if decisions[memberKey] == .pick {
                clearDecision(memberKey)
            }
        }
        replaceCurrentCard(card)
        lightHaptic()
    }

    /// The keeper shown for a card: the user's own pick outranks every
    /// automatic suggestion, then Apple's burst pick, then the ranker.
    func keeperKey(for card: CardModel) -> String? {
        card.group.memberKeys.first { decisions[$0] == .pick }
            ?? card.group.suggestedKeeperKey
            ?? card.suggestion?.key
    }

    /// "Reduce to one": keep the keeper, mark every other member.
    /// Secondary action — picking the single keeper out of several good
    /// frames is the user's judgement, never assumed. The user's own
    /// pick is the keeper whenever one exists.
    func reduceToOne(keeperKey explicitKeeper: String? = nil) {
        guard var card = currentCard else { return }
        let keeper = explicitKeeper
            ?? keeperKey(for: card)
            ?? card.group.representativeKey
        card.markedKeys = Set(
            card.group.memberKeys
                .filter { $0 != keeper && decisions[$0] != .pick }
                // Never mark a member PhotoKit cannot delete — it would
                // only fail the commit transaction later — nor a
                // favourite: the user can still mark one by hand.
                .filter { records[$0]?.isProposable ?? false }
        )
        replaceCurrentCard(card)
        commitHaptic()
    }

    /// Marks the given member as the group's keeper (one-tap override).
    /// Persists as a `pick`, which outranks every automatic suggestion,
    /// unmarks the member, and moves the pick off any sibling — a group
    /// has one keeper.
    func makeKeeper(memberKey: String) {
        guard
            var card = currentCard,
            card.group.memberKeys.contains(memberKey)
        else { return }
        for sibling in card.group.memberKeys
        where sibling != memberKey && decisions[sibling] == .pick {
            clearDecision(sibling)
        }
        recordDecision(memberKey, .pick)
        card.markedKeys.remove(memberKey)
        replaceCurrentCard(card)
        commitHaptic()
    }

    /// Withdraws a pending deletion outside the deck (the review list,
    /// the commit sheet) — the path back for decisions older than the
    /// in-memory undo history.
    func unmark(key: String) {
        guard decisions[key] == .reject else { return }
        clearDecision(key)
        for index in cards.indices { cards[index].markedKeys.remove(key) }
        for index in laterQueue.indices { laterQueue[index].markedKeys.remove(key) }
        lightHaptic()
    }

    /// The live card for a group, for views that outlive a snapshot.
    func card(withID id: String) -> CardModel? {
        (cards + laterQueue).first { $0.id == id }
    }

    /// Asset keys for the sliding prefetch window: the current card's
    /// members plus the representatives of the next few cards.
    func prefetchKeys(lookahead: Int = 4) -> [String] {
        let all = cards + laterQueue
        guard currentIndex >= 0, currentIndex < all.count else { return [] }
        var keys = all[currentIndex].group.memberKeys
        let upper = min(all.count, currentIndex + 1 + lookahead)
        for index in (currentIndex + 1)..<max(upper, currentIndex + 1) {
            keys.append(all[index].group.representativeKey)
        }
        return keys
    }

    // MARK: - Reload

    /// The engine re-ran (new analysis data, library change). Keeps
    /// decisions and undo history; tries to stay on the same card.
    /// Groups this deck already resolved carry `.resolved` state from
    /// persistence, so they drop out naturally — the undo stack is the
    /// belt-and-braces source for resolutions still in flight.
    func reload(groups: [PhotoGroup], records: [AssetRecord]) {
        let currentID = currentCard?.id
        let resolvedHere = Set(undoStack.map(\.groupID))
        // Cards that survive the reload keep what the user did to them:
        // mark edits, the ranked suggestion, and a place in the later
        // pile.
        let previous = Dictionary(
            (cards + laterQueue).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let deferredIDs = laterQueue.map(\.id)

        var fresh: [CardModel] = []
        var deferred: [String: CardModel] = [:]
        for group in groups where group.state == .pending && !resolvedHere.contains(group.id) {
            var card = CardModel(group: group, markedKeys: Self.initialMarks(group, decisions: decisions))
            if let old = previous[group.id] {
                card.markedKeys = old.markedKeys.intersection(group.memberKeys)
                card.suggestion = old.suggestion
            }
            if deferredIDs.contains(group.id) {
                deferred[group.id] = card
            } else {
                fresh.append(card)
            }
        }

        cards = fresh
        laterQueue = deferredIDs.compactMap { deferred[$0] }
        let all = cards + laterQueue
        if let currentID, let index = all.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        } else {
            currentIndex = min(currentIndex, all.count)
        }
        self.records = Dictionary(
            records.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        Task {
            await rankCurrentCard()
        }
    }

    /// Permanently ignores the current card's group: it will not come
    /// back on any launch. Without this the user re-reviews groups they
    /// already decided to keep, and the deck gets abandoned.
    func dismissCurrentCard() {
        guard let card = currentCard else { return }
        let groupID = card.group.id
        enqueueWrite {
            await self.persistence.saveGroupState(id: groupID, state: .dismissed)
        }
        commitHaptic()
        if currentIndex < cards.count {
            cards.remove(at: currentIndex)
        } else if currentIndex - cards.count < laterQueue.count {
            laterQueue.remove(at: currentIndex - cards.count)
        }
        persistSession()
    }

    // MARK: - Undo

    var canUndo: Bool { !undoStack.isEmpty }

    /// Undo steps back through whole cards: a group's members are
    /// restored at once.
    func undo() {
        guard let entry = undoStack.popLast() else { return }
        for (key, decision) in entry.previous {
            decisions[key] = decision
        }
        for key in entry.applied.keys where entry.previous[key] == nil {
            decisions[key] = nil
        }
        let undoEntry = entry
        enqueueWrite {
            if undoEntry.previous.isEmpty {
                await self.persistence.removeDecisions(keys: Array(undoEntry.applied.keys))
            } else {
                await self.persistence.saveDecisions(undoEntry.previous)
            }
            await self.persistence.saveGroupState(id: undoEntry.groupID, state: .pending)
        }

        // Put the card back in front — from wherever it now sits, or
        // from the snapshot when an engine reload dropped it.
        var restored = entry.card
        restored.markedKeys = entry.previousMarks
        restored.group.state = entry.wasResolved
        if let index = cards.firstIndex(where: { $0.id == entry.groupID }) {
            restored = mergedForUndo(cards.remove(at: index), restored)
            if index < currentIndex { currentIndex -= 1 }
        } else if let laterIndex = laterQueue.firstIndex(where: { $0.id == entry.groupID }) {
            restored = mergedForUndo(laterQueue.remove(at: laterIndex), restored)
            if cards.count + laterIndex < currentIndex { currentIndex -= 1 }
        }
        currentIndex = max(0, min(currentIndex, cards.count))
        cards.insert(restored, at: currentIndex)
        if reviewedGroupCount > 0 { reviewedGroupCount -= 1 }
        if reviewedPhotoCount > 0 {
            reviewedPhotoCount -= entry.applied.values.filter(\.isReviewed).count
        }
        undoHaptic()
    }

    // MARK: - Commit candidates

    /// Everything currently marked for deletion: all reject decisions
    /// over deletable assets. The commit sheet's count must match this
    /// exactly.
    var pendingRejects: [String] {
        PhotoKitLibrary.deletionCandidates(from: records, decisions: decisions)
    }

    /// Marks after a successful commit: the deleted keys are cleared
    /// and the library is rescanned by the owner.
    func clearDecisions(keys: [String]) {
        for key in keys {
            decisions[key] = nil
        }
        enqueueWrite {
            await self.persistence.removeDecisions(keys: keys)
        }
    }

    func members(of card: CardModel) -> [AssetRecord] {
        card.group.memberKeys.compactMap { records[$0] }
    }

    // MARK: - Ranking (Phase 3)

    /// Ranks the current card's members. Runs lazily, only for cards
    /// near the deck position, on the already-analysed record fields —
    /// battery is the budget, not milliseconds.
    func rankCurrentCard() async {
        guard var card = currentCard, card.suggestion == nil else { return }
        let members = members(of: card)
        guard members.count > 1 else { return }

        let scores = await ranker.rank(members, kind: card.group.kind)
        guard let best = scores.max(by: { $0.total < $1.total }) else { return }
        card.suggestion = best
        replaceCurrentCard(card)
    }

    // MARK: - Internals

    private enum SwipeDirection {
        case keep
        case discard
    }

    private func applySwipe(_ direction: SwipeDirection) {
        guard let card = currentCard else { return }

        // Swipe left discards exactly the marked members. On keep-all
        // kinds there is nothing the card may propose, so the swipe
        // resolves as keep. On a card with several members whose marks
        // the user cleared, the swipe means "nothing here should go".
        // A single-member card with no marks is the user's own call on
        // one photo — swipe left discards it.
        var membersToReject: Set<String> = []
        if direction == .discard && !card.group.kind.defaultsToKeepAll {
            if card.markedKeys.isEmpty && card.group.memberKeys.count == 1 {
                let key = card.group.memberKeys[0]
                if records[key]?.sourceType.isDeletable == true {
                    membersToReject = [key]
                }
            } else {
                // The user's own keeper is never deleted by a swipe;
                // marking it explicitly withdraws the pick first.
                membersToReject = card.markedKeys.filter { decisions[$0] != .pick }
            }
        }

        // Snapshot for undo: previous decisions for the affected keys.
        let affected = membersToReject.union(
            card.group.memberKeys.filter { decisions[$0] != nil }
        )
        let previous: [String: PhotoDecision] = affected.reduce(into: [:]) { result, key in
            if let decision = decisions[key] {
                result[key] = decision
            }
        }

        var applied: [String: PhotoDecision] = [:]
        for key in membersToReject {
            decisions[key] = .reject
            applied[key] = .reject
        }
        // Keeping clears any lingering reject marks from this group's
        // members (e.g. an earlier reduce-to-one that was undone
        // differently).
        if direction == .keep || membersToReject.isEmpty {
            for key in card.group.memberKeys where decisions[key] == .reject {
                decisions[key] = nil
                applied[key] = .unreviewed
            }
        }

        // Haptics on every commit.
        commitHaptic()

        // Persist immediately: killing the app loses nothing.
        if !applied.isEmpty {
            let updates = applied
            enqueueWrite {
                if updates.values.contains(.unreviewed) {
                    await self.persistence.removeDecisions(
                        keys: Array(updates.filter { $1 == .unreviewed }.keys)
                    )
                    await self.persistence.saveDecisions(
                        updates.filter { $1 != .unreviewed }
                    )
                } else {
                    await self.persistence.saveDecisions(updates)
                }
            }
        }
        let groupID = card.group.id
        enqueueWrite {
            await self.persistence.saveGroupState(id: groupID, state: .resolved)
        }

        pushUndo(
            UndoEntry(
                groupID: card.group.id,
                card: card,
                applied: applied,
                previous: previous,
                previousMarks: card.markedKeys,
                wasResolved: .pending
            )
        )

        reviewedGroupCount += 1
        reviewedPhotoCount += card.group.memberKeys.count
        advanceCard()
        persistSession()
    }

    private func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.undoDepth {
            undoStack.removeFirst()
        }
    }

    private func advanceCard() {
        let all = cards + laterQueue
        if currentIndex < all.count - 1 {
            currentIndex += 1
        } else {
            currentIndex = all.count
        }
    }

    /// The engine's confident frames, minus anything the user already
    /// chose to keep.
    private static func initialMarks(
        _ group: PhotoGroup,
        decisions: [String: PhotoDecision]
    ) -> Set<String> {
        Set(group.flaggedKeys.filter { decisions[$0] != .pick })
    }

    /// Undo prefers the snapshot's marks and state but keeps the latest
    /// group (a reload may have refreshed its members' analysis).
    private func mergedForUndo(_ live: CardModel, _ snapshot: CardModel) -> CardModel {
        var merged = live
        merged.markedKeys = snapshot.markedKeys.intersection(live.group.memberKeys)
        merged.group.state = snapshot.group.state
        return merged
    }

    private func clearDecision(_ key: String) {
        decisions[key] = nil
        enqueueWrite {
            await self.persistence.removeDecisions(keys: [key])
        }
    }

    private func recordDecision(_ key: String, _ decision: PhotoDecision) {
        decisions[key] = decision
        enqueueWrite {
            await self.persistence.saveDecision(key: key, decision: decision)
        }
    }

    private func replaceCurrentCard(_ card: CardModel) {
        let allCount = cards.count
        if currentIndex < allCount {
            cards[currentIndex] = card
        } else if currentIndex - allCount < laterQueue.count {
            laterQueue[currentIndex - allCount] = card
        }
    }

    /// Every decision persists immediately; the exact card is stored so
    /// reopening returns to where the user was.
    private func persistSession() {
        let stored = PersistenceStore.StoredSession(
            currentGroupID: currentCard?.id,
            reviewedCount: reviewedGroupCount,
            reviewedPhotoCount: reviewedPhotoCount,
            date: Date()
        )
        session = stored
        enqueueWrite {
            await self.persistence.saveSession(stored)
        }
    }

    // MARK: - Write queue

    /// Serialised persistence writes, so tests (and the "killing the
    /// app loses nothing" guarantee) can await a deterministic point.
    private var writeTask: Task<Void, Never>?

    private func enqueueWrite(_ work: @escaping () async -> Void) {
        writeTask = Task { [previous = writeTask] in
            _ = await previous?.value
            await work()
        }
    }

    /// Awaits every pending persistence write. Test seam; production
    /// never needs to wait.
    func settleWrites() async {
        await writeTask?.value
    }

    // MARK: - Haptics

    private let hapticEngine = UIImpactFeedbackGenerator(style: .medium)

    private func commitHaptic() {
        guard hapticsEnabled else { return }
        hapticEngine.impactOccurred(intensity: 0.9)
    }

    private func lightHaptic() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func undoHaptic() {
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
