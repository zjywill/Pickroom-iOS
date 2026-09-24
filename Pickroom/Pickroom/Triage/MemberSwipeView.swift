import SwiftUI
import PickroomCore

/// Triage's page for the deck's current set: its photos one at a time,
/// large. Swipe left to toss, right to keep; the last photo resolves
/// the set and the next one comes up. Nothing leaves the library until
/// the commit sheet — back (or a shake) undoes one swipe at a time.
struct MemberSwipeView: View {
    @Environment(AppModel.self) private var model
    let deck: DeckModel
    let card: CardModel
    let onIgnore: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isFlying = false
    @State private var inspecting: InspectTarget?

    /// How far the card must travel before letting go decides it.
    private let threshold: CGFloat = 110

    var body: some View {
        let order = deck.memberOrder
        VStack(spacing: 12) {
            header(order: order)
            strip(order: order)
            ZStack {
                if let key = deck.currentMemberKey {
                    let next = order.firstIndex(of: key).flatMap { order.indices.contains($0 + 1) ? order[$0 + 1] : nil }
                    if let next {
                        SwipePhotoCard(assetKey: next, badges: [])
                            .scaleEffect(0.94)
                            .opacity(0.6)
                            .allowsHitTesting(false)
                    }
                    SwipePhotoCard(assetKey: key, badges: badges(for: key))
                        .overlay { stamps }
                        .offset(offset)
                        .rotationEffect(.degrees(Double(offset.width / 22)), anchor: .bottom)
                        .gesture(drag)
                        .onTapGesture { inspecting = InspectTarget(key: key) }
                        .id(key)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityText(for: key, order: order))
                        .accessibilityAction(named: "Toss") { decide(discard: true) }
                        .accessibilityAction(named: "Keep") { decide(discard: false) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .zIndex(1)

            actionBar
        }
        .padding(.top, 6)
        .fullScreenCover(item: $inspecting) { target in
            if model.recordsByKey[target.key]?.mediaType == .video {
                VideoPlayerView(assetKey: target.key)
            } else {
                InspectView(assetKey: target.key)
            }
        }
        .background { hardwareKeyboardShortcuts }
    }

    // MARK: - Header

    private func header(order: [String]) -> some View {
        HStack(spacing: 10) {
            CampTag(text: card.group.kind.title)
            Text("\(min(deck.memberPosition + 1, order.count)) of \(order.count)")
                .font(Camp.display(.subheadline, weight: .semibold))
                .foregroundStyle(Camp.muted)
                .monospacedDigit()
            Spacer(minLength: 0)
            Button(action: onIgnore) {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.sand, edge: Camp.panelEdge, foreground: Camp.muted, size: 36))
            .accessibilityLabel("Ignore this set for good")
        }
        .padding(.horizontal, 16)
    }

    /// The set at a glance: what's been decided (✓ / ✕), where the
    /// user is, and what's still to come.
    private func strip(order: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, key in
                        StripThumb(
                            assetKey: key,
                            decided: index < deck.memberPosition
                                ? (card.markedKeys.contains(key) ? .marked : .keeper)
                                : nil,
                            isCurrent: index == deck.memberPosition
                        )
                        .id(key)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .onChange(of: deck.currentMemberKey) { _, key in
                guard let key else { return }
                withAnimation(.snappy) { proxy.scrollTo(key, anchor: .center) }
            }
        }
        .frame(height: 60)
        .accessibilityHidden(true)
    }

    // MARK: - Card

    private func badges(for key: String) -> [SwipePhotoCard.Badge] {
        var result: [SwipePhotoCard.Badge] = []
        let isKeeper = card.group.memberKeys.count > 1 && card.group.kind.hasBestShot && deck.keeperKey(for: card) == key
        if deck.decisions[key] == .pick {
            result.append(.init(text: "Your pick", systemImage: "star.fill", fill: Camp.keep))
        } else if isKeeper {
            result.append(.init(text: "Best shot", systemImage: "star.fill", fill: Camp.keep))
        }
        // Undecided photos still carry the app's proposal as their mark.
        if card.markedKeys.contains(key) {
            result.append(.init(text: "Suggested: toss", systemImage: "xmark", fill: Camp.toss))
        }
        if model.recordsByKey[key]?.sourceType.isDeletable == false {
            result.append(.init(text: "Can't be deleted here", systemImage: "lock.fill", fill: Camp.stone))
        }
        return result
    }

    /// TOSS / KEEP, fading in with the drag.
    private var stamps: some View {
        let progress = min(abs(offset.width) / threshold, 1)
        return ZStack {
            stamp("TOSS", color: Camp.toss, angle: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(offset.width < 0 ? progress : 0)
            stamp("KEEP", color: Camp.keep, angle: -12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(offset.width > 0 ? progress : 0)
        }
        .padding(24)
        .allowsHitTesting(false)
    }

    private func stamp(_ text: String, color: Color, angle: Double) -> some View {
        Text(text)
            .font(Camp.display(.largeTitle, weight: .heavy))
            .tracking(2)
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Camp.cream.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color, lineWidth: 4))
            .rotationEffect(.degrees(angle))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isFlying else { return }
                offset = CGSize(width: value.translation.width, height: value.translation.height * 0.2)
            }
            .onEnded { value in
                guard !isFlying else { return }
                let travel = value.predictedEndTranslation.width
                if abs(value.translation.width) > threshold || abs(travel) > threshold * 2.5 {
                    decide(discard: value.translation.width < 0)
                } else {
                    withAnimation(.spring(duration: 0.3)) { offset = .zero }
                }
            }
    }

    /// Flies the card off the side it was decided to, then records it.
    private func decide(discard: Bool) {
        guard !isFlying, deck.currentMemberKey != nil else { return }
        isFlying = true
        withAnimation(.easeIn(duration: 0.18)) {
            offset = CGSize(width: discard ? -600 : 600, height: offset.height)
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                deck.swipeMember(discard: discard)
                offset = .zero
            }
            isFlying = false
        }
    }

    // MARK: - Actions

    /// Back · Toss · Later · Keep.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy) { deck.back() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.wood, edge: Camp.woodEdge, size: 48))
            .disabled(!deck.canGoBack)
            .accessibilityLabel("Back one photo")

            Button {
                decide(discard: true)
            } label: {
                Label("Toss", systemImage: "xmark")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ChunkyButtonStyle(fill: Camp.toss, edge: Camp.tossEdge, verticalPadding: 13))

            Button {
                deck.decideLater()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.later, edge: Camp.laterEdge, foreground: Camp.laterInk, size: 48))
            .accessibilityLabel("Decide this set later")

            Button {
                decide(discard: false)
            } label: {
                Label("Keep", systemImage: "checkmark")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ChunkyButtonStyle(fill: Camp.keep, edge: Camp.keepEdge, verticalPadding: 13))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            Camp.paper
                .shadow(color: Camp.panelEdge.opacity(0.6), radius: 0, x: 0, y: -2)
        )
    }

    /// Hardware keyboard: ← toss, → keep, ↑ later, ⌘Z back.
    @ViewBuilder
    private var hardwareKeyboardShortcuts: some View {
        Group {
            Button("Toss") { decide(discard: true) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Keep") { decide(discard: false) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Later") { deck.decideLater() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Back") { deck.back() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!deck.canGoBack)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func accessibilityText(for key: String, order: [String]) -> String {
        var parts = ["Photo \(min(deck.memberPosition + 1, order.count)) of \(order.count)"]
        parts += badges(for: key).map(\.text)
        return parts.joined(separator: ", ")
    }

    private struct InspectTarget: Identifiable {
        let key: String
        var id: String { key }
    }
}

/// One photo, large, on neutral black — judged as a photo, not as a
/// thumbnail.
private struct SwipePhotoCard: View {
    struct Badge: Hashable {
        let text: String
        let systemImage: String
        let fill: Color
    }

    @Environment(AppModel.self) private var model
    let assetKey: String
    let badges: [Badge]

    @State private var image: UIImage?
    @State private var loaded = false

    /// Only the small local (or small iCloud) copy is showing — the
    /// original is in iCloud and triage doesn't download it.
    private var isPreview: Bool {
        guard let image else { return false }
        return !AssetImageProvider.isDisplaySized(image)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.black)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if loaded {
                    Image(systemName: "icloud.slash")
                        .font(.largeTitle)
                        .foregroundStyle(Camp.cream.opacity(0.7))
                } else {
                    CampSpinner(color: Camp.cream)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            // The edge sits under the card only — a shadow on the whole
            // view would double every badge and label.
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Camp.panelEdge)
                    .offset(y: 5)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Label(badge.text, systemImage: badge.systemImage)
                            .font(Camp.display(.subheadline, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(badge.fill))
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if let record = model.recordsByKey[assetKey], record.capturedAt != nil || record.mediaType == .video {
                    HStack(spacing: 6) {
                        if record.mediaType == .video {
                            Image(systemName: "play.fill")
                        }
                        if let date = record.capturedAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Camp.ink.opacity(0.55)))
                    .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isPreview {
                    ICloudPreviewTag().padding(12)
                }
            }
            .task(id: assetKey) {
                image = nil
                loaded = false
                let identifier = String(assetKey.dropFirst("photos:".count))
                image = await model.imageProvider.previewImage(for: identifier)
                loaded = !Task.isCancelled
            }
    }
}

/// A member in the strip above the card.
private struct StripThumb: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
    let decided: DecisionMark.Kind?
    let isCurrent: Bool

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Camp.sand)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(decided == .marked ? 0.45 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isCurrent ? Camp.later : .clear, lineWidth: 3)
            }
            .overlay(alignment: .bottomTrailing) {
                if let decided {
                    DecisionMark(kind: decided, size: 18)
                        .offset(x: 4, y: 4)
                }
            }
            .task(id: assetKey) {
                let identifier = String(assetKey.dropFirst("photos:".count))
                image = await model.imageProvider.thumbnail(for: identifier)
            }
    }
}
