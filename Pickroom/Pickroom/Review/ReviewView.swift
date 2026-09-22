import SwiftUI
import Photos
import PickroomCore

/// Phase 5: review over everything the engine found, with decision
/// filters and per-group detail. Sets are a list (they are
/// descriptions); photos — picks, marked for deletion, a group's
/// members — are grids.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case sets = "Sets"
        case picks = "Picks"
        case rejects = "Marked"
        case video = "Video"

        var id: String { rawValue }
    }

    @State private var filter: Filter = .sets
    @State private var ignoring: PhotoGroup?

    var body: some View {
        VStack(spacing: 0) {
            CampSegmented(options: Filter.allCases, selection: $filter, title: \.rawValue)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 12)

            switch filter {
            case .sets: setsList
            case .picks: picksGrid
            case .rejects: rejectsGrid
            case .video: videoList
            }
        }
        .background(Camp.paper)
        .campDialog(
            isPresented: Binding(
                get: { ignoring != nil },
                set: { if !$0 { ignoring = nil } }
            ),
            title: "Ignore this set for good?",
            message: "It won't come back in the deck. Nothing is deleted — the photos stay in your library.",
            actions: [
                // Capture the set now: closing the dialog clears
                // `ignoring` before the action runs.
                CampDialogAction(title: "Ignore set", role: .destructive) { [ignoring] in
                    if let id = ignoring?.id {
                        Task { await model.dismissGroup(id: id) }
                    }
                },
                .cancel(),
            ]
        )
        // Triage has its own tab; no second way in from here.
        .campNavigationBar("Review")
    }

    // MARK: - Sets

    /// The group list, cheapest decision first, with kind chips. Each
    /// row opens the set; pending sets carry their own ignore button.
    private var setsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Cheapest decision first")
                    .font(Camp.display(.subheadline, weight: .semibold))
                    .foregroundStyle(Camp.muted)
                    .padding(.horizontal, 4)

                if model.groups.isEmpty {
                    VStack(spacing: 14) {
                        Raccoon(mood: .content)
                            .frame(width: 84)
                        Text(model.analysis.isAnalysing
                             ? "Still analysing — sets of similar photos appear here as they're found."
                             : "No sets of similar photos found.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Camp.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                ForEach(model.groups) { group in
                    HStack(spacing: 10) {
                        NavigationLink {
                            GroupDetailView(groups: model.groups, startID: group.id)
                        } label: {
                            HStack(spacing: 10) {
                                SetRow(group: group)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.heavy))
                                    .foregroundStyle(Camp.panelEdge)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if group.state == .pending {
                            Button {
                                ignoring = group
                            } label: {
                                Image(systemName: "eye.slash.fill")
                            }
                            .buttonStyle(RoundChunkyButtonStyle(
                                fill: Camp.sand,
                                edge: Camp.panelEdge,
                                foreground: Camp.muted,
                                size: 38
                            ))
                            .accessibilityLabel("Ignore this set")
                        }
                    }
                    .campPanel(cornerRadius: 18, padding: 14)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Picks

    private var picksGrid: some View {
        let picks = model.records.filter { model.deck?.decisions[$0.key] == .pick }
        return AssetBrowser(
            keys: picks.map(\.key),
            mode: .pick,
            emptyMessage: "No picks yet. Open a set from a card and choose its keeper."
        ) {
            footnote("Picks live on this device only — they don't sync to the Mac app, though deletions do.")
        }
    }

    // MARK: - Marked for deletion

    private var rejectsGrid: some View {
        AssetBrowser(
            keys: model.commitCandidates,
            emptyMessage: "Nothing marked for deletion."
        ) {
            footnote("Changed your mind? Tap a photo to keep it. Nothing is deleted until you commit from the triage deck.")
        }
    }

    // MARK: - Video

    /// Video: the engine never judges one — no grouping, no best shot,
    /// no deletion proposals — but the user can play any video here
    /// and mark the ones they want gone.
    private var videoList: some View {
        AssetBrowser(
            keys: model.videosBiggestFirst(),
            emptyMessage: "No videos."
        ) {
            footnote("A poster frame tells you almost nothing about a video, so Pickroom never suggests deleting one. Biggest first. Tap to mark; ⤢ to play.")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Camp.muted)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }
}

/// One set in the list: its kind as a ribbon, the headline, the
/// flagged count, and whether it's been dealt with.
private struct SetRow: View {
    let group: PhotoGroup

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                CampTag(text: group.kind.title)
                    .scaleEffect(0.85, anchor: .leading)
                Text(group.headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Camp.ink)
            }
            Spacer(minLength: 0)
            if !group.flaggedKeys.isEmpty {
                Text("\(group.flaggedKeys.count)")
                    .font(Camp.display(.subheadline, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(Capsule().fill(Camp.toss))
                    .accessibilityLabel("\(group.flaggedKeys.count) flagged")
            }
            if group.state != .pending {
                Image(systemName: group.state == .dismissed ? "eye.slash" : "checkmark")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(group.state == .dismissed ? Camp.stone : Camp.keep)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Per-group detail from the Sets list: the shared set page, acting on
/// decisions directly, with previous / next through the list. "Keep
/// this · toss the rest" decides the set and moves on to the next
/// undecided one — undo on the toast brings it back.
private struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The list as it was when opened, so the order holds while sets
    /// get decided (their live state is looked up by id).
    let groups: [PhotoGroup]
    @State private var currentID: String
    @State private var toast: BrowserToast?

    init(groups: [PhotoGroup], startID: String) {
        self.groups = groups
        _currentID = State(initialValue: startID)
    }

    private var index: Int { groups.firstIndex { $0.id == currentID } ?? 0 }

    /// The live group (fresh analysis, current state), falling back to
    /// the snapshot.
    private func live(_ id: String) -> PhotoGroup? {
        model.groups.first { $0.id == id } ?? groups.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let group = live(currentID) {
                SetPage(
                    group: group,
                    mode: .toss,
                    onDecided: { snapshot in decided(group, snapshot: snapshot) },
                    externalToast: $toast
                )
                .id(currentID)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
            pager
        }
        .animation(.snappy, value: currentID)
        .background(Camp.paper)
        .campNavigationBar(live(currentID)?.kind.title ?? "Set") {
            CampBarButton(kind: .back) { dismiss() }
        }
    }

    /// ‹ previous · position · next ›
    private var pager: some View {
        HStack(spacing: 12) {
            Button {
                go(to: index - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.cream, edge: Camp.panelEdge, foreground: Camp.ink, size: 46))
            .disabled(index == 0)
            .accessibilityLabel("Previous set")

            Spacer()
            Text("\(index + 1) of \(groups.count)")
                .font(Camp.display(.subheadline, weight: .semibold))
                .foregroundStyle(Camp.muted)
                .monospacedDigit()
            Spacer()

            Button {
                go(to: index + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(RoundChunkyButtonStyle(fill: Camp.cream, edge: Camp.panelEdge, foreground: Camp.ink, size: 46))
            .disabled(index >= groups.count - 1)
            .accessibilityLabel("Next set")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Camp.paper.shadow(color: Camp.panelEdge.opacity(0.6), radius: 0, x: 0, y: -2))
    }

    private func go(to position: Int) {
        guard groups.indices.contains(position) else { return }
        currentID = groups[position].id
    }

    /// The set is decided: resolve it, raise the undo toast, and move to
    /// the next undecided set after it (or back to the list).
    private func decided(_ group: PhotoGroup, snapshot: DeckModel.DecisionSnapshot) {
        let id = group.id
        Task { await model.setGroupState(id: id, .resolved) }
        toast = BrowserToast(
            message: "Kept the best · ^[\(group.memberKeys.count - 1) other](inflect: true) marked",
            snapshot: snapshot,
            onUndo: {
                Task { await model.setGroupState(id: id, .pending) }
                currentID = id
            }
        )
        let after = groups[(index + 1)...]
        if let next = after.first(where: { live($0.id)?.state == .pending && $0.id != id }) {
            currentID = next.id
        } else {
            dismiss()
        }
    }
}
