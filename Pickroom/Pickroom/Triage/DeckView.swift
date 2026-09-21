import SwiftUI
import Photos
import PickroomCore

/// The deck: one card at a time, full screen, thumb-driven. The entire
/// value is rhythm — no confirmation dialogs during triage; safety
/// comes from undo and from nothing leaving the library until an
/// explicit commit.
struct DeckView: View {
    @Environment(AppModel.self) private var model
    let deck: DeckModel

    @State private var dragOffset: CGSize = .zero
    @State private var inspecting: InspectTarget?
    @State private var showingGroupSheet = false
    @State private var showingCommit = false

    struct InspectTarget: Identifiable {
        let assetKey: String
        var id: String { assetKey }
    }

    var body: some View {
        Group {
            if let card = deck.currentCard {
                cardStack(card)
            } else {
                finishedView
            }
        }
        .navigationTitle("Triage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCommit = true
                } label: {
                    Label("Commit", systemImage: "trash")
                }
                .disabled(model.commitCandidates.isEmpty)
            }
        }
        .sheet(isPresented: $showingCommit) {
            CommitSheet()
                .environment(model)
        }
        // Hardware keyboard (iPad): the same four decisions, same
        // rhythm, without the thumb. Phase 5 parity with the Mac app's
        // keyboard-first heritage.
        .background { hardwareKeyboardShortcuts }
    }

    @ViewBuilder
    private var hardwareKeyboardShortcuts: some View {
        Group {
            Button("Keep") { deck.keep() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Discard") { deck.discard() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Later") { deck.decideLater() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Inspect") {
                if let card = deck.currentCard {
                    inspecting = InspectTarget(assetKey: card.group.representativeKey)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Undo") { deck.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!deck.canUndo)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Card stack

    @ViewBuilder
    private func cardStack(_ card: CardModel) -> some View {
        VStack(spacing: 0) {
            progressHeader
            Spacer(minLength: 8)

            CardView(
                card: card,
                deck: deck,
                dragOffset: $dragOffset,
                onSwipe: handleSwipe,
                onTap: { inspecting = InspectTarget(assetKey: card.group.representativeKey) },
                onLongPress: { showingGroupSheet = true }
            )
            .padding(.horizontal)

            Spacer(minLength: 8)
            footer
        }
        .fullScreenCover(item: $inspecting) { target in
            InspectView(assetKey: target.assetKey)
                .environment(model)
        }
        .sheet(isPresented: $showingGroupSheet) {
            GroupSheet(groupID: card.id, deck: deck)
                .environment(model)
        }
        .task(id: card.id) {
            prefetchWindow()
            await deck.rankCurrentCard()
        }
        .shakeToUndo(deck: deck)
    }

    private var progressHeader: some View {
        VStack(spacing: 4) {
            Text(deck.progressText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if let suggestion = deck.currentCard?.suggestion,
               !suggestion.reasons.isEmpty {
                Text(suggestion.reasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Text("Keyboard: → keep · ← discard · ↑ later · Space inspect · ⌘Z undo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            // Persistent, thumb-reachable undo.
            Button {
                deck.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .disabled(!deck.canUndo)
            .accessibilityLabel("Undo last decision")

            Spacer()

            if let card = deck.currentCard, !card.markedKeys.isEmpty {
                Text("\(card.markedKeys.count) marked")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                deck.decideLater()
            } label: {
                Label("Later", systemImage: "clock.arrow.circlepath")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.bottom, 12)
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("All sets reviewed")
                .font(.title2.bold())
            if !model.commitCandidates.isEmpty {
                Text("\(model.commitCandidates.count.formatted()) photos are marked for deletion.")
                    .foregroundStyle(.secondary)
                Button("Review and delete") {
                    showingCommit = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing is marked for deletion. Good work.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Gestures

    private func handleSwipe(_ swipe: DeckViewSwipe) {
        switch swipe {
        case .keep: deck.keep()
        case .discard: deck.discard()
        case .later: deck.decideLater()
        }
        dragOffset = .zero
    }

    /// Sliding prefetch window around the deck position — the current
    /// card's members and the next cards — mandatory at this scale; a
    /// 50,000-photo library cannot load on demand.
    private func prefetchWindow() {
        let identifiers = deck.prefetchKeys().map { String($0.dropFirst("photos:".count)) }
        Task {
            await model.imageProvider.prefetch(window: identifiers)
        }
    }
}

// MARK: - Shake to undo

/// Shake-to-undo on top of the always-visible button.
extension View {
    @ViewBuilder
    func shakeToUndo(deck: DeckModel) -> some View {
        modifier(ShakeToUndoModifier(deck: deck))
    }
}
