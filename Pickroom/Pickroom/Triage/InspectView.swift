import SwiftUI
import Photos

/// Tap a card → inspect larger, pinch to zoom. Full-resolution zoom
/// for focus inspection is deliberately deferred (a desk activity);
/// this is the phone-appropriate version.
struct InspectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let assetKey: String

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            SimultaneousGesture(
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
                                    },
                                DragGesture()
                                    .onChanged { value in
                                        guard scale > 1 else { return }
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
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
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            let identifier = String(assetKey.dropFirst("photos:".count))
            image = await model.imageProvider.cardImage(for: identifier)
        }
    }
}
