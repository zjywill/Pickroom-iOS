import SwiftUI
import Photos
import PickroomCore

/// Triage: one set at a time, one photo at a time — swipe left to
/// toss, right to keep; the set's last photo brings up the next set.
/// No confirmation dialogs during triage; safety comes from Back (undo)
/// and from nothing leaving the library until an explicit commit.
struct DeckView: View {
    @Environment(AppModel.self) private var model
    let deck: DeckModel

    @State private var showingCommit = false
    @State private var deletedBanner: AppModel.CommitReport?
    @State private var confirmingIgnore = false
    @State private var confirmingStartOver = false

    var body: some View {
        Group {
            if let card = deck.currentCard {
                setStack(card)
            } else {
                finishedView
            }
        }
        .background(Camp.paper)
        .campNavigationBar(background: Camp.paper) {
            HStack(spacing: 8) {
                CampBackButtonIfPushed()
                startOverButton
            }
        } center: {
            if deck.currentCard != nil {
                progressPill
            }
        } trailing: {
            commitButton
        }
        .campDialog(
            isPresented: $confirmingStartOver,
            title: "Start over?",
            message: "Every mark and pick is cleared and all sets come back, from the first one. Nothing in your library changes.",
            actions: [
                CampDialogAction(title: "Start over", role: .destructive) {
                    Task { await model.startOver(includingIgnored: false) }
                },
                CampDialogAction(title: "Start over + ignored sets", role: .cancel) {
                    Task { await model.startOver(includingIgnored: true) }
                },
                .cancel(),
            ]
        )
        .sheet(isPresented: $showingCommit) {
            CommitSheet()
                .environment(model)
                .campSheet()
        }
        .overlay(alignment: .top) {
            if let report = deletedBanner {
                DeletedBanner(report: report) {
                    deletedBanner = nil
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: deletedBanner)
        .onChange(of: model.lastCommitReport) { _, report in
            deletedBanner = report
        }
        .task(id: deletedBanner) {
            guard deletedBanner != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { deletedBanner = nil }
        }
    }

    // MARK: - Set page

    @ViewBuilder
    private func setStack(_ card: CardModel) -> some View {
        MemberSwipeView(deck: deck, card: card) {
            confirmingIgnore = true
        }
        // A fresh page per set: the walk starts at this set's first photo.
        .id(card.id)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        .animation(.snappy, value: card.id)
        .campDialog(
            isPresented: $confirmingIgnore,
            title: "Ignore this set for good?",
            message: "It won't come back. Nothing is deleted — the photos stay in your library.",
            actions: [
                CampDialogAction(title: "Ignore set", role: .destructive) {
                    deck.dismissCurrentCard()
                },
                .cancel(),
            ]
        )
        .task(id: card.id) {
            prefetchWindow()
            // The keeper leads the walk; rank before the first swipe.
            await deck.rankCurrentCard()
        }
        .shakeToUndo(deck: deck)
    }

    /// Clears every decision and runs the deck again from the top.
    private var startOverButton: some View {
        Button {
            confirmingStartOver = true
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(RoundChunkyButtonStyle(fill: Camp.cream, edge: Camp.panelEdge, foreground: Camp.ink, size: 44))
        .accessibilityLabel("Start over")
    }

    /// Progress in sets — never in gigabytes.
    private var progressPill: some View {
        VStack(spacing: 6) {
            Text(deck.progressText)
                .font(Camp.display(.subheadline, weight: .semibold))
                .foregroundStyle(Camp.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
    }

    /// The commit button, carrying the marked count — the only way out
    /// of triage that deletes anything.
    private var commitButton: some View {
        Button {
            showingCommit = true
        } label: {
            Image(systemName: "trash.fill")
        }
        .buttonStyle(RoundChunkyButtonStyle(fill: Camp.toss, edge: Camp.tossEdge, size: 44))
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
                Button {
                    confirmingStartOver = true
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.campPlain)
                .padding(.top, 4)
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

/// After a commit: what happened and where the photos went, in one
/// banner that leaves by itself.
private struct DeletedBanner: View {
    let report: AppModel.CommitReport
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: "checkmark", fill: Camp.keep, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("^[\(report.deletedCount) photo](inflect: true) deleted")
                    .font(Camp.display(.headline, weight: .semibold))
                    .foregroundStyle(Camp.ink)
                Text("In Recently Deleted for 30 days. Space comes back once it's emptied — in Photos.")
                    .font(.footnote)
                    .foregroundStyle(Camp.muted)
                Link(destination: URL(string: "photos-redirect://")!) {
                    Label("Open Photos", systemImage: "arrow.up.right")
                }
                .buttonStyle(ChunkyButtonStyle(
                    fill: Camp.wood,
                    edge: Camp.woodEdge,
                    cornerRadius: 12,
                    font: .caption.weight(.heavy),
                    horizontalPadding: 12,
                    verticalPadding: 6
                ))
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.sand, edge: Camp.panelEdge, foreground: Camp.muted, size: 30))
            .accessibilityLabel("Dismiss")
        }
        .campPanel(padding: 14)
    }
}
