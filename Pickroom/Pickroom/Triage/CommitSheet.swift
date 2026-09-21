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
    @State private var showReport = false

    var body: some View {
        Group {
            if model.commitCandidates.isEmpty {
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
        .sheet(isPresented: $showReport) {
            ReportView()
                .environment(model)
                .campSheet()
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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

                    rejectGrid

                    Text("Touch and hold a photo to keep it instead.")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Camp.muted)
                        .frame(maxWidth: .infinity)

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
                .padding(20)
            }

            commitBar
        }
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

    /// The full set as a grid — evidence, before anything leaves the
    /// library.
    private var rejectGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
            spacing: 12
        ) {
            ForEach(model.commitCandidates, id: \.self) { key in
                // Touch and hold keeps the photo straight away — it
                // leaves this grid, which is the confirmation.
                RejectThumb(assetKey: key)
                    .onLongPressGesture(minimumDuration: 0.4) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy) { model.deck?.unmark(key: key) }
                    }
                    .accessibilityAction(named: "Keep this photo") {
                        model.deck?.unmark(key: key)
                    }
            }
        }
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
        .disabled(isCommitting)
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
            if success {
                showReport = true
            }
            // A cancelled system confirmation is not an error; stay on
            // the sheet so the user can try again or cancel.
        }
    }
}

private struct RejectThumb: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
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
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Camp.panelEdge)
                .offset(y: 3)
        )
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.thumbnail(for: identifier)
        }
    }
}

/// The post-commit report: photos deleted first, the live Recently
/// Deleted pending figure, and storage before/after — evidence the
/// session was worth it, never a promise made in advance.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report = model.lastCommitReport {
                    VStack(spacing: 10) {
                        Raccoon(mood: .content)
                            .frame(width: 96)
                        Text("\(report.deletedCount.formatted()) photos deleted")
                            .font(Camp.display(.title, weight: .semibold))
                            .foregroundStyle(Camp.ink)
                        Label(
                            "Moved to Recently Deleted — erased after 30 days",
                            systemImage: "clock.badge.checkmark"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Camp.muted)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        CampTag(text: "Space")
                        storageRow(report)
                        if report.storageBefore.totalCapacity > 0 {
                            // The device storage bar the user already
                            // has an intuition for.
                            StorageBar(
                                available: report.storageBefore.availableCapacity,
                                total: report.storageBefore.totalCapacity
                            )
                        }
                    }
                    .campPanel(padding: 18)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "trash.fill", fill: Camp.wood, size: 36)
                        Text("\(model.recentlyDeletedPending.formatted()) photos pending in Recently Deleted")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Camp.ink)
                    }
                    Text("Space is not freed until Recently Deleted is emptied. Pickroom will never empty it for you — that step is yours, in the Photos app.")
                        .font(.footnote)
                        .foregroundStyle(Camp.muted)
                    Link(destination: URL(string: "photos-redirect://")!) {
                        Label("Open Photos", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.wood)
                    .padding(.top, 4)
                }
                .campPanel(padding: 18)
            }
            .padding(20)
        }
        .background(Camp.sheet)
        .campNavigationBar("Session report", background: Camp.sheet, showsGrabber: true) {
            EmptyView()
        } trailing: {
            CampBarButton(kind: .done) { dismiss() }
        }
    }

    @ViewBuilder
    private func storageRow(_ report: AppModel.CommitReport) -> some View {
        let after = DeviceStorageSnapshot.current()
        let freed = after.availableCapacity - report.storageBefore.availableCapacity
        if freed > 0 {
            Text("About \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed on this device")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Camp.ink)
        } else {
            Text("Storage updates may lag a moment while iOS reconciles")
                .font(.subheadline)
                .foregroundStyle(Camp.muted)
        }
    }
}

/// The device storage bar, before/after.
struct StorageBar: View {
    let available: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geometry in
            let used = max(0, min(1, 1 - Double(available) / Double(max(total, 1))))
            ZStack(alignment: .leading) {
                Capsule().fill(Camp.sand)
                Capsule()
                    .fill(Camp.later)
                    .frame(width: geometry.size.width * used)
            }
        }
        .frame(height: 12)
        .accessibilityLabel("Storage \(Int((1 - Double(available) / Double(max(total, 1))) * 100)) percent used")
    }
}
