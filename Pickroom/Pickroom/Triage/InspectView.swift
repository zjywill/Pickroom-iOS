import SwiftUI
import Photos

/// Tap a card → inspect larger, pinch to zoom. Full-resolution zoom
/// for focus inspection is deliberately deferred (a desk activity);
/// this is the phone-appropriate version.
struct InspectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let assetKey: String
    var showsClose = true

    @State private var display = DisplayImageState()
    private var image: UIImage? { display.image }
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = max(1, min(6, lastScale * value))
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale <= 1.01 {
                                        withAnimation(.spring(response: 0.3)) {
                                            scale = 1
                                            lastScale = 1
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                                }
                        )
                        // Panning only while zoomed in, so a swipe at 1×
                        // still pages the viewer.
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                },
                            including: scale > 1 ? .all : .subviews
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.3)) {
                                if scale > 1 {
                                    scale = 1
                                    lastScale = 1
                                    offset = .zero
                                    lastOffset = .zero
                                } else {
                                    scale = 2.5
                                    lastScale = 2.5
                                }
                            }
                        }
                } else {
                    CampSpinner(color: Camp.cream)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Photos are judged against neutral black, not the camp
            // palette; only the control is themed.
            .background(.black)

            if showsClose {
                CampBarButton(kind: .close) { dismiss() }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            ICloudBadge(state: display)
                .padding(.bottom, 180)
        }
        .task(id: assetKey) {
            let identifier = String(assetKey.dropFirst("photos:".count))
            for await update in model.imageProvider.displayImage(for: identifier) {
                display.apply(update)
            }
        }
    }
}

/// A photo on screen, arriving: local first, then from iCloud when the
/// phone only keeps a small copy.
struct DisplayImageState {
    var image: UIImage?
    var downloadProgress: Double?
    var unavailable = false

    mutating func apply(_ update: AssetImageProvider.DisplayUpdate) {
        switch update {
        case let .image(image, isFinal):
            self.image = image
            if isFinal { downloadProgress = nil }
        case let .downloading(progress):
            downloadProgress = progress
        case .unavailable:
            downloadProgress = nil
            unavailable = true
        }
    }
}

/// "Downloading from iCloud 40%" while a display copy is fetched, or
/// why only a small copy is showing.
struct ICloudBadge: View {
    let state: DisplayImageState

    var body: some View {
        Group {
            if let progress = state.downloadProgress {
                Label(
                    "Downloading from iCloud \(progress.formatted(.percent.precision(.fractionLength(0))))",
                    systemImage: "icloud.and.arrow.down"
                )
            } else if state.unavailable {
                Label("In iCloud — couldn't download it now", systemImage: "icloud.slash")
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Camp.ink.opacity(0.7)))
        .opacity(state.downloadProgress != nil || state.unavailable ? 1 : 0)
        .monospacedDigit()
    }
}
