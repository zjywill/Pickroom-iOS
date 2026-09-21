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
        .background { MeadowBackground() }
        .navigationTitle("Triage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
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
            topRow
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            cardHeader(card)
                .padding(.horizontal, 24)

            CardView(
                card: card,
                deck: deck,
                dragOffset: $dragOffset,
                onSwipe: handleSwipe,
                onTap: { inspecting = InspectTarget(assetKey: card.group.representativeKey) },
                onLongPress: { showingGroupSheet = true }
            )
            .padding(.horizontal, 28)
            .zIndex(1)

            Spacer(minLength: 12)
            swipeHints(card)
            Spacer(minLength: 12)
            footer
                .padding(.horizontal, 16)
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

    /// Progress in sets, and the commit button carrying the marked
    /// count — the only way out of triage that deletes anything.
    private var topRow: some View {
        HStack {
            VStack(spacing: 6) {
                Text(deck.progressText)
                    .font(Camp.display(.subheadline, weight: .semibold))
                    .foregroundStyle(Camp.ink)
                    .monospacedDigit()
                CampProgressBar(
                    value: Double(deck.reviewedGroupCount) / Double(max(deck.totalCardCount, 1)),
                    fill: Camp.keep,
                    edge: Camp.keepEdge,
                    height: 6
                )
                .frame(width: 96)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Camp.cream)
                    .shadow(color: Camp.meadowEdge, radius: 0, x: 0, y: 4)
            )

            Spacer()

            Button {
                showingCommit = true
            } label: {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.toss, edge: Camp.tossEdge))
            .overlay(alignment: .topTrailing) {
                if !model.commitCandidates.isEmpty {
                    Text(model.commitCandidates.count.formatted())
                        .font(Camp.display(.caption, weight: .bold))
                        .foregroundStyle(Camp.toss)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Camp.cream))
                        .offset(x: 6, y: -6)
                        .allowsHitTesting(false)
                }
            }
            .disabled(model.commitCandidates.isEmpty)
            .accessibilityLabel("Commit, \(model.commitCandidates.count) marked")
        }
    }

    /// The situation headline — kind, what the app is sure of, and the
    /// suggestion's reasons — with the raccoon peeking over the card.
    private func cardHeader(_ card: CardModel) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                CampTag(text: card.group.kind.title)
                Text(card.group.headline)
                    .font(Camp.display(.title2, weight: .semibold))
                    .foregroundStyle(Camp.forestInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = card.suggestion, !suggestion.reasons.isEmpty {
                    Text("Suggested: \(suggestion.reasons.joined(separator: " · "))")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Camp.mossInk)
                }
                if card.group.kind == .failedFrame && card.group.flaggedKeys.isEmpty {
                    Text("Your call — nothing is proposed automatically")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Camp.mossInk)
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Text("Keyboard: → keep · ← discard · ↑ later · Space inspect · ⌘Z undo")
                        .font(.caption2)
                        .foregroundStyle(Camp.mossInk)
                }
            }
            .padding(.bottom, 14)
            Spacer(minLength: 0)
            Raccoon(mood: dragOffset.width < -24 ? .oops : .watching)
                .frame(width: 80)
                .offset(x: -18, y: 16)
                .animation(.snappy, value: dragOffset.width < -24)
        }
    }

    /// Standing reminder of the three directions, in decision colours.
    private func swipeHints(_ card: CardModel) -> some View {
        HStack {
            hint("Toss", systemImage: "arrow.left", color: Camp.toss)
            Spacer()
            hint("Later", systemImage: "arrow.up", color: Camp.laterInk)
            Spacer()
            hint(card.group.kind.defaultsToKeepAll || card.group.memberKeys.count == 1 ? "Keep" : "Keep all", systemImage: "arrow.right", color: Camp.keep)
        }
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }

    private func hint(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(Camp.display(.subheadline, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Camp.cream.opacity(0.75)))
    }

    private var footer: some View {
        HStack {
            // Persistent, thumb-reachable undo.
            Button {
                deck.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(ChunkyButtonStyle(fill: Camp.wood, edge: Camp.woodEdge, horizontalPadding: 16, verticalPadding: 11))
            .disabled(!deck.canUndo)
            .accessibilityLabel("Undo last decision")

            Spacer()

            if let card = deck.currentCard, !card.markedKeys.isEmpty {
                Text("\(card.markedKeys.count) marked")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Camp.toss)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Camp.cream.opacity(0.85)))
            }

            Spacer()

            Button {
                deck.decideLater()
            } label: {
                Label("Later", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(ChunkyButtonStyle(
                fill: Camp.later,
                edge: Camp.laterEdge,
                foreground: Camp.laterInk,
                horizontalPadding: 16,
                verticalPadding: 11
            ))
        }
        .padding(.bottom, 12)
    }

    /// Dusk at camp: everything reviewed. No score, no streak — just
    /// what is marked and the way to act on it.
    private var finishedView: some View {
        ZStack(alignment: .bottom) {
            DuskScene()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        let scale = geometry.size.width / 390
                        Raccoon(mood: .content, pose: .sitting)
                            .frame(width: 118 * scale)
                            .offset(x: 44 * scale, y: 332 * scale)
                    }
                }
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Text("All sets reviewed")
                    .font(Camp.display(.largeTitle, weight: .semibold))
                    .foregroundStyle(Camp.ink)
                if !model.commitCandidates.isEmpty {
                    Text("^[\(model.commitCandidates.count) photo](inflect: true) marked for deletion.")
                        .foregroundStyle(Camp.muted)
                    Button {
                        showingCommit = true
                    } label: {
                        Label("Review and delete", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChunkyButtonStyle(
                        fill: Camp.toss,
                        edge: Camp.tossEdge,
                        cornerRadius: 22,
                        font: Camp.display(.title3, weight: .semibold),
                        verticalPadding: 16
                    ))
                    .padding(.top, 12)
                } else {
                    Text("Nothing is marked for deletion. Good work.")
                        .foregroundStyle(Camp.muted)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous)
                    .fill(Camp.sheet)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        // The scene is drawn to width; below it, the camp ground
        // continues rather than the deck's meadow.
        .background(Color(hex: 0x6E8B4E).ignoresSafeArea())
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
