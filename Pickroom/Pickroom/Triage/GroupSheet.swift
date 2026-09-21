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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(card)

                    if let suggestion = card.suggestion,
                       !suggestion.reasons.isEmpty {
                        Label(
                            "Suggested keeper: \(suggestion.reasons.joined(separator: " · "))",
                            systemImage: "sparkles"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    memberGrid(card)

                    if !card.group.kind.defaultsToKeepAll && card.group.memberKeys.count > 1 {
                        // Secondary, deliberate: picking the single
                        // keeper out of several good frames is the
                        // user's judgement, not the app's.
                        Section {
                            Button {
                                deck.reduceToOne()
                                dismiss()
                            } label: {
                                Label(
                                    "Reduce to one — discard the rest",
                                    systemImage: "square.stack.3d.up.slash"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        } header: {
                            Text("Secondary action")
                                .font(.footnote.bold())
                                .foregroundStyle(.secondary)
                        }

                        // Permanently ignore this group.
                        Button(role: .destructive) {
                            deck.dismissCurrentCard()
                            dismiss()
                        } label: {
                            Label("Ignore this set permanently", systemImage: "eye.slash")
                        }
                        .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationTitle(card.group.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func header(_ card: CardModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.group.headline)
                .font(.title3.bold())
            if let span = card.group.span {
                Text(span.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func memberGrid(_ card: CardModel) -> some View {
        let keeperKey = deck.keeperKey(for: card)
        return 
LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), spacing: 8)],
            spacing: 8
        ) {
            ForEach(card.group.memberKeys, id: \.self) { key in
                GroupMemberCell(
                    assetKey: key,
                    isMarked: card.markedKeys.contains(key),
                    isKeeper: key == keeperKey,
                    decision: deck.decisions[key],
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
    let decision: PhotoDecision?
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
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if isMarked {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .red)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isKeeper {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isMarked ? Color.red : (isKeeper ? Color.green : .clear),
                        lineWidth: 2
                    )
            )
            .onTapGesture(perform: onTap)

            Menu {
                Button("Make this the keeper", action: onMakeKeeper)
            } label: {
                Text(decisionLabel)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.thumbnail(for: identifier)
        }
    }

    private var decisionLabel: String {
        if isKeeper { return "Keeper" }
        if isMarked { return "Discarding" }
        if let decision {
            return decision.title
        }
        return "Tap to mark"
    }
}
