import SwiftUI
import Photos
import PickroomCore

/// Long press a card → the whole group: every member, its marks, the
/// best-shot suggestion with its reason, and the secondary "reduce to
/// one" action. Reducing a clean burst is offered, never assumed.
struct GroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupID: String
    let deck: DeckModel

    @State private var confirmingIgnore = false

    var body: some View {
        // Read the live card on every render — a snapshot taken when
        // the sheet opened would not show the marks the user taps.
        if let card = deck.card(withID: groupID) {
            content(card)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func content(_ card: CardModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(card)

                if let suggestion = card.suggestion,
                   !suggestion.reasons.isEmpty {
                    HStack(spacing: 10) {
                        IconBadge(systemImage: "sparkles", fill: Camp.keep, size: 30)
                        Text("Suggested keeper: \(suggestion.reasons.joined(separator: " · "))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Camp.mossInk)
                    }
                }

                memberGrid(card)

                if !card.group.kind.defaultsToKeepAll && card.group.memberKeys.count > 1 {
                    // Secondary, deliberate: picking the single
                    // keeper out of several good frames is the
                    // user's judgement, not the app's.
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Secondary action")
                            .font(Camp.display(.footnote, weight: .bold))
                            .foregroundStyle(Camp.muted)
                        Button {
                            deck.reduceToOne()
                            dismiss()
                        } label: {
                            Label(
                                "Reduce to one — discard the rest",
                                systemImage: "square.stack.3d.up.slash"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.later)
                    }
                    .padding(.top, 8)

                    // Permanently ignore this group.
                    Button {
                        confirmingIgnore = true
                    } label: {
                        Label("Ignore this set permanently", systemImage: "eye.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.campPlain)
                }
            }
            .padding(20)
        }
        .background(Camp.sheet)
        .campNavigationBar(card.group.kind.title, background: Camp.sheet, showsGrabber: true) {
            EmptyView()
        } trailing: {
            CampBarButton(kind: .done) { dismiss() }
        }
        .campDialog(
            isPresented: $confirmingIgnore,
            title: "Ignore this set for good?",
            message: "It won't come back in the deck. Nothing is deleted — the photos stay in your library.",
            actions: [
                CampDialogAction(title: "Ignore set", role: .destructive) {
                    deck.dismissCurrentCard()
                    dismiss()
                },
                .cancel(),
            ]
        )
    }

    private func header(_ card: CardModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.group.headline)
                .font(Camp.display(.title2, weight: .semibold))
                .foregroundStyle(Camp.ink)
            if let span = card.group.span {
                Text(span.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Camp.muted)
            }
        }
    }

    private func memberGrid(_ card: CardModel) -> some View {
        let keeperKey = deck.keeperKey(for: card)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), spacing: 10)],
            spacing: 14
        ) {
            ForEach(card.group.memberKeys, id: \.self) { key in
                GroupMemberCell(
                    assetKey: key,
                    isMarked: card.markedKeys.contains(key),
                    isKeeper: key == keeperKey,
                    onTap: {
                        deck.toggleMark(memberKey: key)
                    },
                    onMakeKeeper: {
                        deck.makeKeeper(memberKey: key)
                    }
                )
            }
        }
    }
}

/// One cell in the group sheet grid.
private struct GroupMemberCell: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
    let isMarked: Bool
    let isKeeper: Bool
    let onTap: () -> Void
    let onMakeKeeper: () -> Void

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Camp.sand)
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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

            // The keeper is labelled; every other frame offers to
            // become it — one tap, no menu.
            if isKeeper {
                Text("Keeper")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Camp.keep)
                    .padding(.vertical, 5)
            } else {
                Button("Make keeper", action: onMakeKeeper)
                    .buttonStyle(ChunkyButtonStyle(
                        fill: Camp.cream,
                        edge: Camp.panelEdge,
                        foreground: Camp.ink,
                        cornerRadius: 12,
                        font: .caption.weight(.heavy),
                        horizontalPadding: 10,
                        verticalPadding: 5
                    ))
            }
        }
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.thumbnail(for: identifier)
        }
    }
}
