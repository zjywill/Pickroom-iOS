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
        .navigationTitle("Review")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if let deck = model.deck {
                        DeckView(deck: deck)
                    } else {
                        EmptyView()
                    }
                } label: {
                    Label("Triage", systemImage: "rectangle.stack")
                }
            }
        }
    }

    // MARK: - Sets

    /// The group list, cheapest decision first, with kind chips.
    private var setsList: some View {
        List {
            Section {
                ForEach(model.groups) { group in
                    NavigationLink {
                        GroupDetailView(group: group)
                    } label: {
                        SetRow(group: group)
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Camp.cream)
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        if group.state == .pending {
                            Button("Ignore") {
                                Task { await model.dismissGroup(id: group.id) }
                            }
                            .tint(Camp.stone)
                        }
                    }
                }
            } header: {
                Text("Cheapest decision first")
                    .font(Camp.display(.subheadline, weight: .semibold))
                    .foregroundStyle(Camp.muted)
                    .textCase(nil)
            }
        }
        .listRowSpacing(10)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Picks

    private var picksGrid: some View {
        let picks = model.records.filter { model.deck?.decisions[$0.key] == .pick }
        return ScrollView {
            if picks.isEmpty {
                emptyText("No picks yet. Long-press a card, then choose a member as the keeper.")
            } else {
                PhotoGrid(keys: picks.map(\.key), decisionFor: { _ in .pick })
                    .padding(.horizontal)
            }
            footnote("Picks live on this device only — they don't sync to the Mac app, though deletions do.")
        }
    }

    // MARK: - Marked for deletion

    private var rejectsGrid: some View {
        let rejects = model.commitCandidates
        return ScrollView {
            if rejects.isEmpty {
                emptyText("Nothing marked for deletion.")
            } else {
                PhotoGrid(
                    keys: rejects,
                    decisionFor: { _ in .reject },
                    unmark: { key in model.deck?.unmark(key: key) }
                )
                .padding(.horizontal)
            }
            footnote("Touch and hold a photo to keep it instead. Nothing is deleted until you commit from the triage deck.")
        }
    }

    // MARK: - Video

    /// Video: counted, filterable, and otherwise left alone — no
    /// grouping, no best shot, no deletion proposals. Viewing happens
    /// in Photos.
    private var videoList: some View {
        List {
            Section {
                let videos = model.records.filter(\.isContainedVideo)
                if videos.isEmpty {
                    Text("No videos.")
                        .foregroundStyle(Camp.muted)
                        .listRowBackground(Camp.cream)
                }
                ForEach(videos) { record in
                    HStack {
                        AssetRow(record: record)
                        Spacer()
                        Link(
                            "Photos",
                            destination: URL(string: "photos-redirect://")!
                        )
                        .font(.caption.weight(.heavy))
                    }
                    .listRowBackground(Camp.cream)
                }
            } header: {
                Text("Video")
                    .font(Camp.display(.subheadline, weight: .semibold))
                    .foregroundStyle(Camp.muted)
                    .textCase(nil)
            } footer: {
                Text("A poster frame tells you almost nothing about a video, so Pickroom never judges one. Screen recordings are the exception — they live with expired screenshots.")
                    .foregroundStyle(Camp.muted)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func emptyText(_ text: String) -> some View {
        VStack(spacing: 14) {
            Raccoon(mood: .content)
                .frame(width: 84)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Camp.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Camp.muted)
            .padding()
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

/// A thumbnail grid of assets with decision badges. When `unmark` is
/// given, each photo offers "Keep this photo" — the way back for a
/// deletion decided in an earlier session, beyond the undo history.
private struct PhotoGrid: View {
    let keys: [String]
    let decisionFor: (String) -> PhotoDecision?
    var flagged: Set<String> = []
    var unmark: ((String) -> Void)?

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
            spacing: 12
        ) {
            ForEach(keys, id: \.self) { key in
                let cell = GridThumb(
                    assetKey: key,
                    decision: decisionFor(key),
                    isFlagged: flagged.contains(key)
                )
                if let unmark, decisionFor(key) == .reject {
                    cell
                        .contextMenu {
                            Button("Keep this photo", systemImage: "arrow.uturn.backward") {
                                unmark(key)
                            }
                        }
                        .accessibilityAction(named: "Keep this photo") { unmark(key) }
                } else {
                    cell
                }
            }
        }
    }
}

private struct GridThumb: View {
    @Environment(AppModel.self) private var model
    let assetKey: String
    let decision: PhotoDecision?
    let isFlagged: Bool

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Camp.sand)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: 3)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Camp.panelEdge)
                    .offset(y: 3)
            )
            .overlay(alignment: .bottomTrailing) { badge.padding(5) }
            .task(id: assetKey) {
                let identifier = String(assetKey.dropFirst("photos:".count))
                image = await model.imageProvider.thumbnail(for: identifier)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var badge: some View {
        switch decision {
        case .pick?:
            DecisionMark(kind: .keeper)
        case .reject?:
            DecisionMark(kind: .marked)
        default:
            if isFlagged {
                DecisionMark(kind: .flagged)
            }
        }
    }

    private var ringColor: Color {
        switch decision {
        case .pick?: Camp.keep
        case .reject?: Camp.toss
        default: .clear
        }
    }

    private var accessibilityText: String {
        switch decision {
        case .pick?: "Keeper"
        case .reject?: "Marked for deletion"
        default: isFlagged ? "Flagged as clearly bad" : "Photo"
        }
    }
}

/// Simple asset row with thumbnail (videos).
private struct AssetRow: View {
    @Environment(AppModel.self) private var model
    let record: AssetRecord

    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Camp.sand)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.fileName ?? record.key)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Camp.ink)
                    .lineLimit(1)
                if let date = record.capturedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(Camp.muted)
                }
            }
        }
        .task(id: record.key) {
            let identifier = String(record.key.dropFirst("photos:".count))
            image = await model.imageProvider.thumbnail(for: identifier)
        }
    }
}

/// Per-group detail: every member as a grid, with the app's flags and
/// the user's decisions. Marked members can be kept from here.
private struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: PhotoGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CampTag(text: group.kind.title)
                Text(group.headline)
                    .font(Camp.display(.title2, weight: .semibold))
                    .foregroundStyle(Camp.ink)
                if let span = group.span {
                    Text(span.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Camp.muted)
                }
                PhotoGrid(
                    keys: group.memberKeys,
                    decisionFor: { model.deck?.decisions[$0] },
                    flagged: Set(group.flaggedKeys),
                    unmark: { key in model.deck?.unmark(key: key) }
                )
                if !group.flaggedKeys.isEmpty {
                    Text("\(group.flaggedKeys.count) of \(group.memberKeys.count) are flagged as clearly bad (○). The default action removes exactly these; ✕ marks what you chose to delete.")
                        .font(.footnote)
                        .foregroundStyle(Camp.muted)
                        .campPanel(padding: 14)
                        .padding(.top, 6)
                }
            }
            .padding()
        }
        .background(Camp.paper)
        .navigationTitle(group.kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
