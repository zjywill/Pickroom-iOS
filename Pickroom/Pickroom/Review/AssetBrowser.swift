import SwiftUI
import AVFoundation
import Photos
import PickroomCore

/// Where a photo stands in its set's ranking, for the set detail.
enum RankTier {
    case best, good, weaker

    var title: String {
        switch self {
        case .best: "Best"
        case .good: "Good"
        case .weaker: "Weaker"
        }
    }

    var fill: Color {
        switch self {
        case .best: Camp.keep
        case .good: Camp.lake
        case .weaker: Camp.stone
        }
    }
}

/// An undo toast shown under a browser grid.
struct BrowserToast: Equatable {
    let id = UUID()
    let message: String
    let snapshot: DeckModel.DecisionSnapshot
    /// Anything beyond restoring decisions (reopening a decided set).
    var onUndo: (@MainActor () -> Void)?

    static func == (a: BrowserToast, b: BrowserToast) -> Bool { a.id == b.id }
}

/// What a tap on a grid cell toggles.
enum BrowserMode {
    /// Marked for deletion ↔ kept. Every grid except Picks.
    case toss
    /// Picked ↔ not picked. The Picks grid.
    case pick
    /// Marks on the deck's current set (the Triage set page): taps edit
    /// the set's marks, and "Next set" turns them into decisions.
    case deckCard

    @MainActor
    func isOn(_ key: String, model: AppModel) -> Bool {
        let decision = model.deck?.decisions[key]
        switch self {
        case .toss: return decision == .reject
        case .pick: return decision == .pick
        case .deckCard: return model.deck?.currentCard?.markedKeys.contains(key) == true
        }
    }

    /// Marking for deletion (as opposed to picking).
    var isTossLike: Bool { self != .pick }

    /// Whether a tap can change this cell at all — PhotoKit can't
    /// delete shared or synced items, so those only open.
    @MainActor
    func canToggle(_ key: String, model: AppModel) -> Bool {
        switch self {
        case .toss, .deckCard: return model.recordsByKey[key]?.sourceType.isDeletable == true
        case .pick: return true
        }
    }

    @MainActor
    func toggle(_ key: String, model: AppModel) {
        guard let deck = model.deck, canToggle(key, model: model) else { return }
        let on = isOn(key, model: model)
        switch self {
        case .toss: on ? deck.keep(keys: [key]) : deck.markForDeletion(keys: [key])
        case .pick: on ? deck.removePicks(keys: [key]) : deck.pick(keys: [key])
        case .deckCard: deck.toggleMark(memberKey: key)
        }
    }
}

/// The one way photos are handled in a grid, everywhere in the app:
/// **tap a photo to mark it, tap again to keep it** — the same as the
/// deck's member strip — and the corner button to look closer. Nothing
/// here deletes; marking only queues photos for the commit sheet.
///
/// Photos stay where they are after a tap, even in a list of marked
/// photos, so a mis-tap is undone by tapping again rather than by
/// hunting for where the photo went.
struct AssetBrowser<Header: View, Footer: View>: View {
    @Environment(AppModel.self) private var model
    let keys: [String]
    var mode: BrowserMode = .toss
    var flagged: Set<String> = []
    var emptyMessage = "Nothing here."
    var cellSize: CGFloat = 104
    /// Set detail only: each member's place in the ranking, the current
    /// best, and how to make another photo the best.
    var ranks: [String: RankTier] = [:]
    var bestKey: String?
    var onMakeBest: ((String) -> Void)?
    /// The "tap a photo to mark it" line; off where the page is
    /// deliberately terse (the set page).
    var showsHint = true
    /// Lets the header raise the undo toast (the set's "keep this, toss
    /// the rest"). The browser keeps its own when not given.
    var externalToast: Binding<BrowserToast?>?
    @ViewBuilder var header: () -> Header
    @ViewBuilder var footer: () -> Footer

    /// The grid's contents: `keys` as first shown, plus anything that
    /// joins later. Items don't leave while the screen is open.
    @State private var shown: [String] = []
    /// What was on when the screen opened, to label what the user
    /// turned off as "Kept".
    @State private var initiallyOn: Set<String> = []
    @State private var didLoad = false
    @State private var viewing: ViewerTarget?
    @State private var internalToast: BrowserToast?

    private var toast: BrowserToast? {
        get { externalToast?.wrappedValue ?? internalToast }
        nonmutating set {
            if let externalToast { externalToast.wrappedValue = newValue } else { internalToast = newValue }
        }
    }

    struct ViewerTarget: Identifiable {
        let key: String
        var id: String { key }
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header()
                if shown.isEmpty {
                    emptyState
                } else {
                    summaryRow
                    grid
                }
                footer()
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let toast {
                toastView(toast)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            shown = keys
            initiallyOn = Set(keys.filter { mode.isOn($0, model: model) })
        }
        .onChange(of: keys) { _, now in
            // Keep what's on screen (unless it left the library) and
            // append newcomers.
            let current = Set(now)
            var merged = shown.filter { current.contains($0) || model.recordsByKey[$0] != nil }
            let present = Set(merged)
            merged.append(contentsOf: now.filter { !present.contains($0) })
            shown = merged
        }
        .fullScreenCover(item: $viewing) { target in
            AssetViewer(keys: shown, startKey: target.key, mode: mode, bestKey: bestKey, onMakeBest: onMakeBest)
                .environment(model)
        }
        .task(id: toast?.id) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Parts

    private var onCount: Int { shown.filter { mode.isOn($0, model: model) }.count }

    /// Count, how-to, and the two bulk actions. The buttons drop to
    /// their own line when the row is too narrow — never a wrapped label.
    private var summaryRow: some View {
        let on = onCount
        let onKeys = shown.filter { mode.isOn($0, model: model) }
        let offToggleable = shown.filter { !mode.isOn($0, model: model) && mode.canToggle($0, model: model) }
        let size = mode.isTossLike ? model.totalSize(of: onKeys) : 0

        let count = HStack(spacing: 6) {
            Text("^[\(shown.count) item](inflect: true)")
                .foregroundStyle(Camp.muted)
            if on > 0 {
                Text(mode.isTossLike
                     ? "· \(on) marked" + (size > 0 ? " (\(size.formatted(.byteCount(style: .file))))" : "")
                     : "· \(on) picked")
                    .foregroundStyle(mode.isTossLike ? Camp.toss : Camp.keep)
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)

        let buttons = HStack(spacing: 8) {
            if mode.isTossLike, !offToggleable.isEmpty {
                Button("Toss all \(offToggleable.count)") {
                    if mode == .deckCard {
                        model.deck?.setMarks(Set(onKeys + offToggleable))
                    } else {
                        bulk(message: "^[\(offToggleable.count) item](inflect: true) marked") {
                            $0.markForDeletion(keys: offToggleable)
                        }
                    }
                }
                .buttonStyle(smallChip(fill: Camp.cream, edge: Camp.panelEdge, ink: Camp.toss))
            }
            if on > 0 {
                Button(mode.isTossLike ? "Keep all" : "Unpick all") {
                    switch mode {
                    case .deckCard:
                        model.deck?.setMarks([])
                    case .toss:
                        bulk(message: "^[\(on) item](inflect: true) kept") { $0.keep(keys: onKeys) }
                    case .pick:
                        bulk(message: "^[\(on) pick](inflect: true) removed") { $0.removePicks(keys: onKeys) }
                    }
                }
                .buttonStyle(smallChip(fill: Camp.cream, edge: Camp.panelEdge, ink: Camp.keep))
            }
        }
        .lineLimit(1)
        .fixedSize()

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    count
                    Spacer(minLength: 8)
                    buttons
                }
                VStack(alignment: .leading, spacing: 8) {
                    count
                    buttons
                }
            }
            .font(Camp.display(.subheadline, weight: .semibold))
            .monospacedDigit()

            if showsHint {
                Label(
                    mode.isTossLike
                        ? "Tap a photo to mark it · tap again to keep it"
                        : "Tap a photo to unpick it · tap again to pick it",
                    systemImage: "hand.tap.fill"
                )
                .font(.footnote.weight(.bold))
                .foregroundStyle(Camp.muted)
            }
        }
        .padding(.horizontal, 4)
    }

    private func smallChip(fill: Color, edge: Color, ink: Color) -> ChunkyButtonStyle {
        ChunkyButtonStyle(
            fill: fill,
            edge: edge,
            foreground: ink,
            cornerRadius: 14,
            font: Camp.display(.subheadline, weight: .semibold),
            horizontalPadding: 12,
            verticalPadding: 7
        )
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: cellSize), spacing: 10)],
            spacing: 12
        ) {
            ForEach(shown, id: \.self) { key in
                let on = mode.isOn(key, model: model)
                GridThumb(
                    assetKey: key,
                    mode: mode,
                    isOn: on,
                    wasOn: initiallyOn.contains(key),
                    canToggle: mode.canToggle(key, model: model),
                    isFlagged: flagged.contains(key),
                    rank: ranks[key],
                    onToggle: {
                        withAnimation(.snappy(duration: 0.18)) { mode.toggle(key, model: model) }
                    },
                    onExpand: { viewing = ViewerTarget(key: key) }
                )
            }
        }
    }

    private func toastView(_ toast: BrowserToast) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(toast.message))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button("Undo") {
                model.deck?.restore(toast.snapshot)
                toast.onUndo?()
                self.toast = nil
            }
            .buttonStyle(smallChip(fill: Camp.cream, edge: Camp.panelEdge, ink: Camp.ink))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Camp.ink)
        )
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Raccoon(mood: .content)
                .frame(width: 84)
            Text(emptyMessage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Camp.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Bulk actions are the only ones big enough to need an undo toast;
    /// a single tap is undone by tapping again.
    private func bulk(message: String, _ perform: (DeckModel) -> DeckModel.DecisionSnapshot) {
        guard let deck = model.deck else { return }
        let snapshot = withAnimation(.snappy) { perform(deck) }
        guard !snapshot.isEmpty else { return }
        toast = BrowserToast(message: message, snapshot: snapshot)
    }
}

extension AssetBrowser where Header == EmptyView {
    init(
        keys: [String],
        mode: BrowserMode = .toss,
        flagged: Set<String> = [],
        emptyMessage: String = "Nothing here.",
        cellSize: CGFloat = 104,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.init(
            keys: keys,
            mode: mode,
            flagged: flagged,
            emptyMessage: emptyMessage,
            cellSize: cellSize,
            header: { EmptyView() },
            footer: footer
        )
    }
}

// MARK: - Thumbnail

/// A square thumbnail you tap to mark. The top-right disc is the mark
/// — an empty ring until tapped, then a red ✕ (or a green ✓ in Picks);
/// the top-left button opens the photo large.
struct GridThumb: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
    let mode: BrowserMode
    let isOn: Bool
    /// On when the screen opened — turning it off shows "Kept".
    let wasOn: Bool
    let canToggle: Bool
    let isFlagged: Bool
    var rank: RankTier?
    let onToggle: () -> Void
    let onExpand: () -> Void

    @State private var image: UIImage?

    private var record: AssetRecord? { model.recordsByKey[assetKey] }
    private var onColor: Color { mode.isTossLike ? Camp.toss : Camp.keep }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Camp.sand)
                }
            }
            .overlay {
                // A tossed photo recedes, so what stays reads at a glance.
                if isOn && mode.isTossLike {
                    Camp.ink.opacity(0.35)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? onColor : .clear, lineWidth: 3)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Camp.panelEdge)
                    .offset(y: 3)
            )
            .overlay(alignment: .topTrailing) { markDisc.padding(6) }
            .overlay(alignment: .bottomLeading) {
                if let rank {
                    Text(rank.title)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(rank.fill))
                        .padding(6)
                } else {
                    durationLabel.padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) { statusBadge.padding(6) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture {
                if canToggle {
                    onToggle()
                    UISelectionFeedbackGenerator().selectionChanged()
                } else {
                    onExpand()
                }
            }
            .overlay(alignment: .topLeading) { expandButton }
            .task(id: assetKey) {
                let identifier = String(assetKey.dropFirst("photos:".count))
                image = await model.imageProvider.thumbnail(for: identifier)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityHint(canToggle ? (mode.isTossLike ? "Double-tap to mark or keep" : "Double-tap to pick or unpick") : "")
            .accessibilityAction(named: "View larger", onExpand)
    }

    @ViewBuilder
    private var markDisc: some View {
        if !canToggle {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Camp.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Camp.cream.opacity(0.85)))
        } else if !isOn && mode.isTossLike && rank == .best {
            // The keeper: a green ✓ where the others show ✕ or a ring.
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Camp.keep))
                .overlay(Circle().strokeBorder(Camp.cream, lineWidth: 2))
        } else if isOn {
            Image(systemName: mode.isTossLike ? "xmark" : "checkmark")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(onColor))
                .overlay(Circle().strokeBorder(Camp.cream, lineWidth: 2))
                .transition(.scale.combined(with: .opacity))
        } else {
            Circle()
                .fill(Camp.ink.opacity(0.18))
                .overlay(Circle().strokeBorder(Camp.cream, lineWidth: 2))
                .frame(width: 26, height: 26)
        }
    }

    /// Kept (turned off since the screen opened), the app's own flag,
    /// or — in toss grids — the user's keeper.
    @ViewBuilder
    private var statusBadge: some View {
        if wasOn && !isOn {
            Text(mode.isTossLike ? "Kept" : "Unpicked")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(mode.isTossLike ? Camp.keep : Camp.stone))
        } else if mode.isTossLike, rank == nil, model.deck?.decisions[assetKey] == .pick {
            DecisionMark(kind: .keeper, size: 20)
        } else if isFlagged && !isOn {
            DecisionMark(kind: .flagged, size: 20)
        }
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Camp.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Camp.cream.opacity(0.9)))
                .padding(6)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var durationLabel: some View {
        if let duration = record?.duration, record?.mediaType == .video {
            let time = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
            let size = model.fileSizes[assetKey].map { " · " + $0.formatted(.byteCount(style: .file)) } ?? ""
            Label(time + size, systemImage: "play.fill")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Camp.ink.opacity(0.6)))
        }
    }

    private var accessibilityText: String {
        let kind = (record?.mediaType == .video ? "Video" : "Photo") + (rank.map { ", \($0.title.lowercased())" } ?? "")
        if !canToggle { return "\(kind), shared or synced — can't be deleted" }
        switch mode {
        case .toss, .deckCard:
            if isOn { return "\(kind), marked for deletion" }
            return isFlagged ? "\(kind), flagged as clearly bad" : kind
        case .pick:
            return isOn ? "\(kind), picked" : kind
        }
    }
}

// MARK: - Viewer

/// Full-screen look through a grid: swipe between items, pinch a photo,
/// play a video — and mark or keep from the button at the bottom, so
/// checking a whole set closely is one swipe and one tap per photo.
struct AssetViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let keys: [String]
    let mode: BrowserMode

    @State private var current: String

    var bestKey: String?
    var onMakeBest: ((String) -> Void)?

    init(keys: [String], startKey: String, mode: BrowserMode, bestKey: String? = nil, onMakeBest: ((String) -> Void)? = nil) {
        self.keys = keys
        self.mode = mode
        self.bestKey = bestKey
        self.onMakeBest = onMakeBest
        _current = State(initialValue: startKey)
    }

    var body: some View {
        TabView(selection: $current) {
            ForEach(keys, id: \.self) { key in
                page(key)
                    .tag(key)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(.black)
        .ignoresSafeArea()
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { markButton }
    }

    @ViewBuilder
    private func page(_ key: String) -> some View {
        if model.recordsByKey[key]?.mediaType == .video {
            VideoPlayerView(assetKey: key, showsClose: false, isCurrent: key == current)
        } else {
            InspectView(assetKey: key, showsClose: false)
        }
    }

    private var topBar: some View {
        HStack {
            if let index = keys.firstIndex(of: current) {
                Text("\(index + 1) of \(keys.count)")
                    .font(Camp.display(.subheadline, weight: .semibold))
                    .foregroundStyle(Camp.ink)
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Camp.cream))
            }
            Spacer()
            CampBarButton(kind: .close) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var markButton: some View {
        VStack(spacing: 10) {
            if let onMakeBest {
                if current == bestKey {
                    Label("Best shot", systemImage: "star.fill")
                        .font(Camp.display(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Camp.keep))
                } else {
                    Button {
                        onMakeBest(current)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label("Set as best", systemImage: "star")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.keep)
                }
            }
            toggleButton
        }
        .padding(.bottom, model.recordsByKey[current]?.mediaType == .video ? 110 : 24)
    }

    @ViewBuilder
    private var toggleButton: some View {
        if mode.canToggle(current, model: model) {
            let on = mode.isOn(current, model: model)
            Button {
                withAnimation(.snappy) { mode.toggle(current, model: model) }
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                Label(label(on: on), systemImage: symbol(on: on))
                    .frame(minWidth: 220)
            }
            .buttonStyle(style(on: on))
        }
    }

    private func label(on: Bool) -> String {
        switch mode {
        case .toss, .deckCard: on ? "Marked — tap to keep" : "Mark for deletion"
        case .pick: on ? "Picked — tap to unpick" : "Pick again"
        }
    }

    private func symbol(on: Bool) -> String {
        switch mode {
        case .toss, .deckCard: on ? "xmark" : "trash.fill"
        case .pick: on ? "checkmark" : "star.fill"
        }
    }

    private func style(on: Bool) -> ChunkyButtonStyle {
        switch mode {
        case .toss, .deckCard: on ? .toss : .campPlain
        case .pick: on ? .keep : .campPlain
        }
    }
}

/// In-app video playback on camp controls — a play button and a
/// scrubber, no system player chrome. Local renditions only: the
/// no-network contract covers playback too, so a video that lives only
/// in iCloud says so and hands off to Photos.
struct VideoPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let assetKey: String
    var showsClose = true
    /// Only the page on screen plays; neighbours stay paused.
    var isCurrent = true

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var unavailable = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let player {
                    PlayerLayerView(player: player)
                        .onTapGesture { togglePlayback() }
                } else if unavailable {
                    VStack(spacing: 14) {
                        Text("This video isn't on this device — it lives in iCloud. Pickroom never downloads from the network.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Camp.cream)
                            .multilineTextAlignment(.center)
                        Link(destination: URL(string: "photos-redirect://")!) {
                            Label("Open Photos", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.wood)
                    }
                    .padding(32)
                } else {
                    CampSpinner(color: Camp.cream)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

            if showsClose {
                CampBarButton(kind: .close) { dismiss() }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if player != nil { controls }
        }
        .task { await load() }
        .onChange(of: isCurrent) { _, current in
            if !current, isPlaying {
                player?.pause()
                isPlaying = false
            }
        }
        .onDisappear {
            player?.pause()
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.cream, edge: Camp.panelEdge, foreground: Camp.ink, size: 50))
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            VStack(spacing: 6) {
                Scrubber(value: $progress, isScrubbing: $isScrubbing) { fraction in
                    player?.seek(
                        to: CMTime(seconds: fraction * duration, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                HStack {
                    Text(format(progress * duration))
                    Spacer()
                    Text(format(duration))
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Camp.cream)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? seconds : 0).formatted(.time(pattern: .minuteSecond))
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if progress >= 0.999 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying.toggle()
    }

    private func load() async {
        let identifier = String(assetKey.dropFirst("photos:".count))
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
            let url = await Self.localVideoURL(for: asset)
        else {
            unavailable = true
            return
        }
        let player = AVPlayer(url: url)
        duration = asset.duration
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                guard !isScrubbing, duration > 0 else { return }
                progress = min(max(time.seconds / duration, 0), 1)
                if progress >= 0.999 { isPlaying = false }
            }
        }
        self.player = player
        if isCurrent {
            player.play()
            isPlaying = true
        }
    }

    /// The local file behind the video, never a network download.
    /// `nonisolated` so the PhotoKit callback isn't main-actor bound —
    /// PhotoKit calls it on its own queue.
    nonisolated private static func localVideoURL(for asset: PHAsset) async -> URL? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }
}

/// Camp scrubber: a sand track, a later-yellow fill and a cream knob.
private struct Scrubber: View {
    @Binding var value: Double
    @Binding var isScrubbing: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Camp.sand.opacity(0.5)).frame(height: 8)
                Capsule().fill(Camp.later).frame(width: width * value, height: 8)
                Circle()
                    .fill(Camp.cream)
                    .frame(width: 20, height: 20)
                    .shadow(color: Camp.panelEdge, radius: 0, x: 0, y: 2)
                    .offset(x: width * value - 10)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isScrubbing = true
                        value = min(max(drag.location.x / width, 0), 1)
                        onSeek(value)
                    }
                    .onEnded { _ in isScrubbing = false }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
            onSeek(value)
        }
    }
}

/// A bare `AVPlayerLayer`, so no system playback controls appear.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
