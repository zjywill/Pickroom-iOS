import SwiftUI
import Photos
import PickroomCore

/// One card: the representative photo in a polaroid frame, the member
/// strip with tappable marks, and the gesture stamps. The situation
/// headline ("14 shots · 8 blurred" — never a size) sits above the
/// card in `DeckView`, off the photo.
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
            VStack(spacing: 12) {
                photo
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Camp.sand)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(alignment: .topLeading) { suggestedBadge }
                    .overlay { gestureStamps }
                strip
            }
            .padding(12)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Camp.cream)
                    .shadow(color: Color(red: 44 / 255, green: 78 / 255, blue: 36 / 255).opacity(0.32), radius: 0, x: 0, y: 9)
            )
            .rotationEffect(.degrees(-1.5))
            .offset(x: dragOffset.width, y: dragOffset.height)
            .rotationEffect(.degrees(Double(dragOffset.width) / 24))
            .opacity(1 - min(abs(dragOffset.height) / 800, 0.35))
            .contentShape(RoundedRectangle(cornerRadius: 26))
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
                CampSpinner()
            }
        }
    }

    /// Shown when the photo on the card is the one the ranking would
    /// keep — so the strip's green tick and the big photo agree.
    @ViewBuilder
    private var suggestedBadge: some View {
        if !keepAll, keeperKey == card.group.representativeKey, card.group.memberKeys.count > 1 {
            Label("Suggested", systemImage: "checkmark")
                .font(Camp.display(.subheadline, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Camp.keep)
                        .shadow(color: Camp.keepEdge, radius: 0, x: 0, y: 3)
                )
                .padding(10)
        }
    }

    /// The thumbnail strip: tappable to change any frame's mark before
    /// deciding. Marked frames show a ✕; the suggested keeper shows a
    /// checkmark.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(card.group.memberKeys, id: \.self) { key in
                    MemberThumb(
                        assetKey: key,
                        isMarked: card.markedKeys.contains(key),
                        isKeeper: key == keeperKey,
                        onTap: { deck.toggleMark(memberKey: key) }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .frame(height: 64)
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

    /// Swipe affordances: a stamp on the photo that fades in with the
    /// drag and names exactly what letting go will do.
    @ViewBuilder
    private var gestureStamps: some View {
        ZStack {
            if dragOffset.width > 24 {
                stamp(keepAll || card.group.memberKeys.count == 1 ? "KEEP" : "KEEP ALL", systemImage: "checkmark", tint: Camp.keep)
                    .rotationEffect(.degrees(-10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(min(dragOffset.width / 120, 1))
            }
            if dragOffset.width < -24 && discardCount > 0 {
                stamp("TOSS \(discardCount)", systemImage: "trash", tint: Camp.toss)
                    .rotationEffect(.degrees(10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(min(-dragOffset.width / 120, 1))
            }
            if dragOffset.height < -24 {
                stamp("LATER", systemImage: "clock", tint: Camp.laterEdge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(min(-dragOffset.height / 120, 1))
            }
        }
        .padding(18)
        .allowsHitTesting(false)
    }

    private func stamp(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Camp.cream.opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint, lineWidth: 4)
            )
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
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Camp.sand)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isMarked ? Camp.toss : (isKeeper ? Camp.keep : .clear),
                    lineWidth: 3
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if isMarked {
                DecisionMark(kind: .marked).offset(x: 5, y: 5)
            } else if isKeeper {
                DecisionMark(kind: .keeper).offset(x: 5, y: 5)
            }
        }
        .onTapGesture(perform: onTap)
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.thumbnail(for: identifier)
        }
        .accessibilityLabel(isMarked ? "Marked for deletion" : "Keeping")
    }
}
