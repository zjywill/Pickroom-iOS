import SwiftUI
import PickroomCore

/// One set, laid out for a decision: the best shot up top with the
/// one-tap "keep this, toss the rest", then every member ranked
/// best → weaker. Tap a photo to mark it; ⤢ to look closer and make
/// another one the best.
///
/// Used twice: from Review → Sets (`.toss`, acting on decisions
/// directly) and as Triage's page for the deck's current set
/// (`.deckCard`, editing the set's marks until "Next set").
struct SetPage<Footer: View>: View {
    @Environment(AppModel.self) private var model
    let group: PhotoGroup
    let mode: BrowserMode
    /// Called after "keep this, toss the rest" with what it replaced —
    /// the caller moves on to the next set (and, in Review, raises the
    /// undo toast itself so it survives the page change).
    var onDecided: ((DeckModel.DecisionSnapshot) -> Void)?
    /// A toast owned by the caller, so it outlives this page.
    var externalToast: Binding<BrowserToast?>?
    @ViewBuilder var footer: () -> Footer

    @State private var scores: [String: ShotScore]?
    @State private var internalToast: BrowserToast?

    private var toastBinding: Binding<BrowserToast?> {
        externalToast ?? $internalToast
    }

    private var decisions: [String: PhotoDecision] { model.deck?.decisions ?? [:] }

    /// The user's pick, then Apple's burst pick, then the ranking — in
    /// Triage, exactly the deck's keeper, so the ✓ and the marks agree.
    private var bestKey: String? {
        if mode == .deckCard, let deck = model.deck, let card = deck.currentCard, card.id == group.id,
           let keeper = deck.keeperKey(for: card) {
            return keeper
        }
        if let picked = group.memberKeys.first(where: { decisions[$0] == .pick }) { return picked }
        if let suggested = group.suggestedKeeperKey { return suggested }
        return DeckModel.best(of: Array(scores?.values ?? [:].values), order: group.memberKeys)?.key
    }

    /// Best first, then by score.
    private var orderedKeys: [String] {
        let best = bestKey
        let score: (String) -> Double = { scores?[$0]?.total ?? 0 }
        return group.memberKeys.sorted { a, b in
            if a == best { return true }
            if b == best { return false }
            return score(a) > score(b)
        }
    }

    private var canReduce: Bool {
        group.memberKeys.count > 1 && group.kind.hasBestShot
    }

    private var ranks: [String: RankTier] {
        guard canReduce else { return [:] }
        let best = bestKey
        var result: [String: RankTier] = [:]
        for key in group.memberKeys {
            if key == best {
                result[key] = .best
            } else if let total = scores?[key]?.total {
                result[key] = total >= 0.5 ? .good : .weaker
            }
        }
        return result
    }

    var body: some View {
        Group {
            if scores == nil {
                CampLoadingView(message: "Ranking the set…")
            } else {
                AssetBrowser(
                    keys: orderedKeys,
                    mode: mode,
                    flagged: Set(group.flaggedKeys),
                    ranks: ranks,
                    bestKey: canReduce ? bestKey : nil,
                    onMakeBest: canReduce ? { makeBest($0) } : nil,
                    showsHint: false,
                    externalToast: toastBinding
                ) {
                    header
                } footer: {
                    VStack(alignment: .leading, spacing: 12) {
                        if group.kind.defaultsToKeepAll && group.memberKeys.count > 1 {
                            Text("Kept whole — each frame differs on purpose.")
                                .font(.footnote)
                                .foregroundStyle(Camp.muted)
                                .campPanel(padding: 14)
                        }
                        footer()
                    }
                    .padding(.top, 6)
                }
            }
        }
        .task(id: group.id) {
            let members = group.memberKeys.compactMap { model.recordsByKey[$0] }
            let ranked = await FallbackShotRanker().rank(members, kind: group.kind)
            scores = Dictionary(ranked.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Terse: the kind tag in Triage (Review's bar already names it),
    /// and the date inside the best photo. Only a set with no best-shot
    /// card shows the date as a line.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .deckCard || !canReduce {
                HStack(spacing: 10) {
                    if mode == .deckCard {
                        CampTag(text: group.kind.title)
                    }
                    if !canReduce, let span = group.span {
                        Text(span.start.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Camp.muted)
                    }
                }
            }
            if canReduce, let best = bestKey {
                BestShotCard(
                    assetKey: best,
                    reasons: scores?[best]?.reasons ?? [],
                    isUserPick: decisions[best] == .pick,
                    othersCount: group.memberKeys.count - 1,
                    date: group.span?.start,
                    movesOn: onDecided != nil
                ) {
                    keepOnly(best)
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func makeBest(_ key: String) {
        guard let deck = model.deck else { return }
        switch mode {
        case .deckCard: deck.makeKeeper(memberKey: key)
        case .toss, .pick: deck.setKeeper(key, among: group.memberKeys)
        }
    }

    private func keepOnly(_ best: String) {
        guard let deck = model.deck else { return }
        switch mode {
        case .deckCard:
            // Favourites are spared, as everywhere a bulk action runs.
            let rest = group.memberKeys.filter {
                $0 != best && model.recordsByKey[$0]?.isProposable == true
            }
            withAnimation(.snappy) {
                deck.makeKeeper(memberKey: best)
                deck.setMarks(Set(rest))
            }
            onDecided?([:])
        case .toss, .pick:
            let snapshot = withAnimation(.snappy) { deck.keepOnly(best, among: group.memberKeys) }
            if let onDecided {
                onDecided(snapshot)
            } else if !snapshot.isEmpty {
                toastBinding.wrappedValue = BrowserToast(
                    message: "Kept the best · ^[\(group.memberKeys.count - 1) other](inflect: true) marked",
                    snapshot: snapshot
                )
            }
        }
    }
}

extension SetPage where Footer == EmptyView {
    init(
        group: PhotoGroup,
        mode: BrowserMode,
        onDecided: ((DeckModel.DecisionSnapshot) -> Void)? = nil,
        externalToast: Binding<BrowserToast?>? = nil
    ) {
        self.init(group: group, mode: mode, onDecided: onDecided, externalToast: externalToast, footer: { EmptyView() })
    }
}

/// The set's best shot, large, with why — and the one-tap decision.
private struct BestShotCard: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
    let reasons: [String]
    let isUserPick: Bool
    let othersCount: Int
    let date: Date?
    /// Triage: the button also moves on to the next set.
    let movesOn: Bool
    let onKeepOnly: () -> Void

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Camp.sand)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label(isUserPick ? "Your pick" : "Best shot", systemImage: "star.fill")
                        .font(Camp.display(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Camp.keep))
                        .padding(10)
                }
                .overlay(alignment: .bottomLeading) {
                    if let date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Camp.ink.opacity(0.55)))
                            .padding(10)
                    }
                }
            if !reasons.isEmpty {
                Text(reasons.joined(separator: " · "))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Camp.mossInk)
            }
            Button(action: onKeepOnly) {
                Label(
                    movesOn ? "Keep this · toss \(othersCount) · next" : "Keep this · toss the other \(othersCount)",
                    systemImage: "checkmark"
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.keep)
        }
        .campPanel(padding: 12)
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.cardImage(for: identifier)
        }
    }
}
