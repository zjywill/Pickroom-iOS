import SwiftUI
import Photos
import PickroomCore

/// The commit sheet: a grid of everything about to go, wording that
/// matches what will actually happen, and — behind iOS's own system
/// confirmation — one `performChanges` for the whole batch.
///
/// This is the one place in the app where the language is deliberately
/// heavy. Triage is frictionless; the price is that this screen is
/// unambiguous.
struct CommitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isCommitting = false
    @State private var showedGrid = false

    var body: some View {
        Group {
            // Once the grid is up it stays, even when every photo has
            // been tapped to keep — so the last one can be tapped back.
            if model.commitCandidates.isEmpty && !showedGrid {
                emptyState
            } else {
                reviewContent
            }
        }
        .background(Camp.sheet)
        .campNavigationBar("Commit", background: Camp.sheet, showsGrabber: true) {
            CampBarButton(kind: .close, accessibilityLabel: "Cancel") { dismiss() }
                .disabled(isCommitting)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Raccoon(mood: .content)
                .frame(width: 96)
            Text("Nothing is marked for deletion")
                .font(Camp.display(.title3, weight: .semibold))
                .foregroundStyle(Camp.ink)
            Text("Swipe left on a card to discard its clearly-bad frames, then come back here.")
                .font(.subheadline)
                .foregroundStyle(Camp.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewContent: some View {
        VStack(spacing: 0) {
            // Every photo about to go, as evidence. Tap one to keep it
            // (it stays in place, marked "Kept"); ⤢ to look closer.
            AssetBrowser(
                keys: model.commitCandidates,
                cellSize: 88
            ) {
                // Wording that matches what will actually happen.
                HStack(alignment: .top, spacing: 14) {
                    IconBadge(systemImage: "trash.fill", fill: Camp.stone, size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(
                            CommitComposer.headline(
                                count: model.commitCandidates.count,
                                situation: model.diagnosis
                            )
                        )
                        .font(Camp.display(.title2, weight: .semibold))
                        .foregroundStyle(Camp.ink)
                        Text(CommitComposer.supportingLine())
                            .font(.subheadline)
                            .foregroundStyle(Camp.muted)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            } footer: {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Something here you want to keep? Tap it. Tap again to put it back.")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Camp.muted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)

                    if let error = model.lastCommitError {
                        notice(error, systemImage: "exclamationmark.triangle.fill", fill: Color(hex: 0xF9D9CF), badge: Camp.toss, ink: Camp.tossEdge)
                    }

                    if model.diagnosis == .iCloudFullCopies {
                        notice(
                            "Tip: turning on Optimise iPhone Storage in Settings can free space without deleting anything — check that your iCloud plan has room first.",
                            systemImage: "sparkles",
                            fill: Color(hex: 0xE1EDCF),
                            badge: Camp.keep,
                            ink: Color(hex: 0x2F4A28)
                        )
                    }
                }
                .padding(.top, 4)
            }

            commitBar
        }
        .onAppear { showedGrid = true }
    }

    private func notice(_ text: String, systemImage: String, fill: Color, badge: Color, ink: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: systemImage, fill: badge, size: 32)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill))
    }

    private var commitBar: some View {
        Button {
            commit()
        } label: {
            Group {
                if isCommitting {
                    CampSpinner(color: .white)
                } else {
                    Label(
                        CommitComposer.headline(
                            count: model.commitCandidates.count,
                            situation: model.diagnosis
                        ),
                        systemImage: "trash.fill"
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ChunkyButtonStyle(
            fill: Camp.toss,
            edge: Camp.tossEdge,
            cornerRadius: 22,
            font: Camp.display(.headline, weight: .semibold),
            verticalPadding: 16
        ))
        .disabled(isCommitting || model.commitCandidates.isEmpty)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Camp.sheet)
    }

    private func commit() {
        isCommitting = true
        Task {
            // iOS shows its own system confirmation for
            // `deleteAssets` — one alert for the entire batch. This is
            // the only code path in the app that deletes anything.
            let success = await model.commitDeletion()
            isCommitting = false
            // Done: the sheet gets out of the way and the deck shows a
            // self-dismissing banner — nothing more to close after
            // iOS's own confirmation.
            if success {
                dismiss()
            }
            // A cancelled system confirmation is not an error; stay on
            // the sheet so the user can try again or cancel.
        }
    }
}
