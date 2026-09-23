import SwiftUI
import PickroomCore

/// The home screen's "What's in your library" categories.
enum LibraryCategory: String, CaseIterable, Identifiable {
    case all, failedFrames, exactDuplicates, screenshots, screenRecordings, videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Photos and videos"
        case .failedFrames: "Failed frames"
        case .exactDuplicates: "Exact duplicates"
        case .screenshots: "Screenshots"
        case .screenRecordings: "Screen recordings"
        case .videos: "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.fill"
        case .failedFrames: "camera.metering.unknown"
        case .exactDuplicates: "square.on.square.fill"
        case .screenshots: "iphone"
        case .screenRecordings: "record.circle"
        case .videos: "video.fill"
        }
    }

    var color: Color {
        switch self {
        case .all: Camp.lake
        case .failedFrames: Camp.failed
        case .exactDuplicates: Camp.duplicate
        case .screenshots: Camp.screenshot
        case .screenRecordings: Camp.recording
        case .videos: Camp.stone
        }
    }

    var footnote: String? {
        switch self {
        case .videos:
            "Biggest first. Pickroom never suggests deleting a video — tap to mark the ones you want gone; ⤢ to play."
        case .exactDuplicates:
            "Byte-identical copies sit next to each other. Keep one of each."
        case .failedFrames:
            "Frames that aren't photographs of anything — all black, all white, a covered lens. Blurry-looking photos are never listed here: sky, water and night shots fool that check."
        default:
            nil
        }
    }
}

extension AppModel {
    /// The category's members, newest first (duplicates stay together).
    func keys(in category: LibraryCategory) -> [String] {
        let newestFirst: (AssetRecord, AssetRecord) -> Bool = {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        }
        switch category {
        case .all:
            return records.sorted(by: newestFirst).map(\.key)
        case .failedFrames:
            return records.filter { $0.quality?.tier == .obviouslyBroken }.sorted(by: newestFirst).map(\.key)
        case .exactDuplicates:
            return groups.filter { $0.kind == .exactDuplicate }.flatMap(\.memberKeys)
        case .screenshots:
            return records.filter(\.isScreenshot).sorted(by: newestFirst).map(\.key)
        case .screenRecordings:
            return records.filter(\.isScreenRecording).sorted(by: newestFirst).map(\.key)
        case .videos:
            return videosBiggestFirst()
        }
    }

    /// Videos by size on disk, biggest first — where the space is.
    func videosBiggestFirst() -> [String] {
        records
            .filter(\.isContainedVideo)
            .sorted {
                let a = fileSizes[$0.key] ?? 0
                let b = fileSizes[$1.key] ?? 0
                if a != b { return a > b }
                return ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
            }
            .map(\.key)
    }

    /// The tile figure — the engine's summary, so home and grid agree.
    func count(of category: LibraryCategory) -> Int {
        switch category {
        case .all: summary.totalAssets
        case .failedFrames: summary.failedFrameCount
        case .exactDuplicates: summary.exactDuplicateCount
        case .screenshots: summary.screenshotCount
        case .screenRecordings: summary.screenRecordingCount
        case .videos: summary.videoCount
        }
    }
}

/// One library category as a grid: tap to mark for deletion (tap
/// again to keep), ⤢ to look closer or play.
struct LibraryCategoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let category: LibraryCategory

    var body: some View {
        Group {
            // Wait for sizes so "biggest first" is the order the grid
            // opens in (the grid keeps its order once shown).
            if category == .videos && !model.videoSizesReady {
                CampLoadingView(message: "Measuring videos…")
            } else {
                browser
            }
        }
        .background(Camp.paper)
        .campNavigationBar(category.title) {
            CampBarButton(kind: .back) { dismiss() }
        }
    }

    private var browser: some View {
        AssetBrowser(
            keys: model.keys(in: category),
            emptyMessage: "Nothing in \(category.title.lowercased())."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if category == .videos {
                    let total = model.totalSize(of: model.keys(in: .videos))
                    if total > 0 {
                        Text("Your videos take \(total.formatted(.byteCount(style: .file)))")
                            .font(Camp.display(.title3, weight: .semibold))
                            .foregroundStyle(Camp.ink)
                    }
                }
                if let footnote = category.footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(Camp.muted)
                }
                Text("Marking only queues photos. Nothing leaves your library until you commit from the triage deck.")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Camp.muted)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        } footer: {
            EmptyView()
        }
    }
}
