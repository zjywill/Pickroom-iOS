import SwiftUI
import UIKit

/// Shake-to-undo, on top of the always-visible undo button. The deck
/// is one-handed by design; the shake gesture is the other thumb path.
struct ShakeToUndoModifier: ViewModifier {
    let deck: any ShakeResponder

    func body(content: Content) -> some View {
        content
            .background(
                ShakeDetectingView(onShake: {
                    if deck.canUndoShake {
                        deck.undoFromShake()
                    }
                })
                .allowsHitTesting(false)
            )
    }
}

/// The narrow interface the shake modifier needs — avoids exposing the
/// whole DeckModel to UIKit plumbing.
@MainActor
protocol ShakeResponder: AnyObject {
    var canUndoShake: Bool { get }
    func undoFromShake()
}

extension DeckModel: ShakeResponder {
    var canUndoShake: Bool { canUndo }
    func undoFromShake() { undo() }
}

/// UIKit motion → SwiftUI bridge.
private struct ShakeDetectingView: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeDetectingUIView {
        ShakeDetectingUIView(onShake: onShake)
    }

    func updateUIView(_ uiView: ShakeDetectingUIView, context: Context) {}
}

private final class ShakeDetectingUIView: UIView {
    private let onShake: () -> Void

    init(onShake: @escaping () -> Void) {
        self.onShake = onShake
        super.init(frame: .zero)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }
}
