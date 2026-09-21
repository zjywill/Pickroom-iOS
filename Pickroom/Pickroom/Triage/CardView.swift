import SwiftUI
import Photos
import PickroomCore

/// One card: the representative photo, the situation headline, the
/// member strip with tappable marks, and the gesture affordances.
///
/// The card leads with what the app is confident about — the headline
/// describes the situation ("14 shots · 8 blurred") and never leads
/// with a size.
struct CardView: View {
    @Environment(AppModel.self) private var model
    let card: CardModel
    let deck: DeckModel
    @Binding var dragOffset: CGSize
    let onSwipe: (DeckViewSwipe) -> Void
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var image: UIImage?

    private var keepAll: Bool { card.group.kind.defaultsToKeepAll }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .bottom) {
                photo
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(alignment: .top) { headline }
                    .overlay(alignment: .bottom) { strip }

                gestureIndicators(size: size)
            }
            .offset(x: dragOffset.width, y: dragOffset.height)
            .rotationEffect(.degrees(Double(dragOffset.width) / 24))
            .opacity(1 - min(abs(dragOffset.height) / 800, 0.35))
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .gesture(dragGesture(threshold: 120))
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
            .animation(.spring(response: 0.3), value: dragOffset)
        }
        .aspectRatio(0.75, contentMode: .fit)
        .task(id: card.group.representativeKey) {
            let identifier = String(card.group.representativeKey.dropFirst("photos:".count))
            image = await model.imageProvider.cardImage(for: identifier)
        }
    }

    // MARK: - Parts

    private var photo: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                    }
            }
        }
    }

    private var headline: some View {
        VStack(spacing: 2) {
            Text(card.group.kind.title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.8))
            Text(card.group.headline)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .multilineTextAlignment(.center)
            if let suggestion = card.suggestion, !suggestion.reasons.isEmpty {
                Text("Suggested: \(suggestion.reasons.joined(separator: " · "))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if card.group.kind == .failedFrame && card.group.flaggedKeys.isEmpty {
                Text("Your call — nothing is proposed automatically")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// The thumbnail strip: tappable to change any frame's mark before
    /// deciding. Marked frames show a ✕; the suggested keeper shows a
    /// checkmark.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(card.group.memberKeys, id: \.self) { key in
                    MemberThumb(
                        assetKey: key,
                        isMarked: card.markedKeys.contains(key),
                        isKeeper: key == keeperKey,
                        onTap: { deck.toggleMark(memberKey: key) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(height: 92)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var keeperKey: String? {
        deck.keeperKey(for: card)
    }

    /// What a left swipe will actually remove — the indicator must
    /// never promise less (or more) than the deck does.
    private var discardCount: Int {
        guard !keepAll else { return 0 }
        if card.markedKeys.isEmpty && card.group.memberKeys.count == 1 {
            return 1
        }
        return card.markedKeys.filter { deck.decisions[$0] != .pick }.count
    }

    /// Swipe affordances, fading in with the drag.
    @ViewBuilder
    private func gestureIndicators(size: CGSize) -> some View {
        if dragOffset.width > 24 {
            indicator(
                title: "Keep all",
                systemImage: "checkmark",
                tint: .green
            )
            .position(x: size.width - 48, y: size.height * 0.4)
            .opacity(min(dragOffset.width / 120, 1))
        }
        if dragOffset.width < -24 && discardCount > 0 {
            indicator(
                title: "Discard \(discardCount)",
                systemImage: "xmark",
                tint: .red
            )
            .position(x: 48, y: size.height * 0.4)
            .opacity(min(-dragOffset.width / 120, 1))
        }
        if dragOffset.height < -24 {
            indicator(
                title: "Later",
                systemImage: "clock",
                tint: .orange
            )
            .position(x: size.width / 2, y: 40)
            .opacity(min(-dragOffset.height / 120, 1))
        }
    }

    private func indicator(title: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title2.bold())
            Text(title)
                .font(.caption.bold())
        }
        .foregroundStyle(tint)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Gesture

    private func dragGesture(threshold: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let translation = value.translation
                let velocity = value.velocity

                // Horizontal swipe wins when it is clearly horizontal.
                if abs(translation.width) > abs(translation.height) {
                    if translation.width > threshold || velocity.width > 800 {
                        onSwipe(.keep)
                    } else if translation.width < -threshold || velocity.width < -800 {
                        onSwipe(.discard)
                    } else {
                        dragOffset = .zero
                    }
                } else {
                    if translation.height < -threshold || velocity.height < -800 {
                        onSwipe(.later)
                    } else {
                        dragOffset = .zero
                    }
                }
            }
    }
}

/// The swipe directions a card can resolve into.
enum DeckViewSwipe {
    case keep, discard, later
}

/// One member thumbnail with its mark overlay.
private struct MemberThumb: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
    let isMarked: Bool
    let isKeeper: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isMarked {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .red)
                    .padding(4)
            } else if isKeeper {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .green)
                    .padding(4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isMarked ? Color.red : (isKeeper ? Color.green : .clear),
                    lineWidth: 2
                )
        )
        .onTapGesture(perform: onTap)
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.thumbnail(for: identifier)
        }
        .accessibilityLabel(isMarked ? "Marked for deletion" : "Keeping")
    }
}
