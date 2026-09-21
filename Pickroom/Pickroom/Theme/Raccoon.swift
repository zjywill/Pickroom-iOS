import SwiftUI

/// The mascot. Lives in the margins — peeking over a card, sitting by
/// the fire — and never on top of a photo.
struct Raccoon: View {
    enum Mood {
        /// Watching the deck.
        case watching
        /// Something just went in the bin.
        case oops
        /// Everything reviewed.
        case content
    }

    enum Pose {
        case head
        case sitting
    }

    var mood: Mood = .watching
    var pose: Pose = .head

    var body: some View {
        Canvas { context, size in
            switch pose {
            case .head:
                let scale = size.width / 120
                context.scaleBy(x: scale, y: scale)
                Self.drawHead(in: &context, mood: mood)
            case .sitting:
                let scale = size.width / 170
                context.scaleBy(x: scale, y: scale)
                Self.drawBody(in: &context)
                context.translateBy(x: 20, y: 4)
                Self.drawHead(in: &context, mood: mood)
            }
        }
        .aspectRatio(pose == .head ? 120.0 / 112.0 : 170.0 / 186.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    // MARK: - Palette

    private static let fur = Color(hex: 0x8C8790)
    private static let darkFur = Color(hex: 0x6E6A70)
    private static let mask = Color(hex: 0x3A3440)
    private static let stripe = Color(hex: 0x5C5662)
    private static let muzzle = Color(hex: 0xF4EFE8)
    private static let belly = Color(hex: 0xD9D3CB)
    private static let arm = Color(hex: 0x7A7580)
    private static let nose = Color(hex: 0x2A2530)
    private static let pupil = Color(hex: 0x1E1A22)
    private static let blush = Color(hex: 0xF2A7A0)

    // MARK: - Drawing (120 × 112 head box, 170 × 186 body box)

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        ellipse(cx, cy, r, r)
    }

    private static func drawHead(in context: inout GraphicsContext, mood: Mood) {
        for x in [28.0, 92.0] {
            context.fill(circle(x, 30, 17), with: .color(darkFur))
            context.fill(circle(x, 30, 8), with: .color(mask))
        }
        context.fill(ellipse(60, 66, 48, 40), with: .color(fur))
        context.fill(ellipse(60, 85, 32, 20), with: .color(muzzle))

        var stripePath = Path()
        stripePath.move(to: CGPoint(x: 56, y: 28))
        stripePath.addQuadCurve(to: CGPoint(x: 64, y: 28), control: CGPoint(x: 60, y: 25))
        stripePath.addLine(to: CGPoint(x: 63, y: 50))
        stripePath.addQuadCurve(to: CGPoint(x: 57, y: 50), control: CGPoint(x: 60, y: 52))
        stripePath.closeSubpath()
        context.fill(stripePath, with: .color(stripe))

        var maskPath = Path()
        maskPath.move(to: CGPoint(x: 14, y: 62))
        maskPath.addQuadCurve(to: CGPoint(x: 60, y: 56), control: CGPoint(x: 28, y: 44))
        maskPath.addQuadCurve(to: CGPoint(x: 106, y: 62), control: CGPoint(x: 92, y: 44))
        maskPath.addQuadCurve(to: CGPoint(x: 80, y: 73), control: CGPoint(x: 98, y: 78))
        maskPath.addQuadCurve(to: CGPoint(x: 40, y: 73), control: CGPoint(x: 60, y: 66))
        maskPath.addQuadCurve(to: CGPoint(x: 14, y: 62), control: CGPoint(x: 22, y: 78))
        maskPath.closeSubpath()
        context.fill(maskPath, with: .color(mask))

        switch mood {
        case .content:
            for x in [42.0, 78.0] {
                var lid = Path()
                lid.move(to: CGPoint(x: x - 6, y: 63))
                lid.addQuadCurve(to: CGPoint(x: x + 6, y: 63), control: CGPoint(x: x, y: 57))
                context.stroke(lid, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        case .watching, .oops:
            for x in [42.0, 78.0] {
                context.fill(circle(x, 62, 7), with: .color(.white))
                context.fill(circle(x + 1.5, 63, 4), with: .color(pupil))
                context.fill(circle(x + 3, 61.5, 1.4), with: .color(.white))
            }
        }

        context.fill(ellipse(60, 80, 7, 5), with: .color(nose))

        switch mood {
        case .oops:
            context.fill(ellipse(60, 92, 4, 4.5), with: .color(nose))
        case .watching, .content:
            var mouth = Path()
            mouth.move(to: CGPoint(x: 53, y: 89))
            mouth.addQuadCurve(to: CGPoint(x: 67, y: 89), control: CGPoint(x: 60, y: 95))
            context.stroke(mouth, with: .color(nose), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }

        context.fill(ellipse(36, 88, 6, 3.5), with: .color(blush.opacity(0.75)))
        context.fill(ellipse(84, 88, 6, 3.5), with: .color(blush.opacity(0.75)))
    }

    private static func drawBody(in context: inout GraphicsContext) {
        var tail = Path()
        tail.move(to: CGPoint(x: 104, y: 150))
        tail.addQuadCurve(to: CGPoint(x: 150, y: 96), control: CGPoint(x: 156, y: 146))
        context.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 28, lineCap: .round))
        context.stroke(tail, with: .color(mask), style: StrokeStyle(lineWidth: 28, dash: [12, 13], dashPhase: 4))

        context.fill(ellipse(80, 138, 42, 38), with: .color(fur))
        context.fill(ellipse(80, 148, 25, 24), with: .color(belly))
        context.fill(ellipse(60, 176, 15, 7), with: .color(mask))
        context.fill(ellipse(100, 176, 15, 7), with: .color(mask))

        for (x, angle) in [(58.0, 20.0), (102.0, -20.0)] {
            let rotation = CGAffineTransform(translationX: x, y: 140)
                .rotated(by: angle * .pi / 180)
                .translatedBy(x: -x, y: -140)
            context.fill(ellipse(x, 140, 9, 15).applying(rotation), with: .color(arm))
        }
    }
}

#Preview {
    HStack {
        Raccoon(mood: .watching).frame(width: 90)
        Raccoon(mood: .oops).frame(width: 90)
        Raccoon(mood: .content, pose: .sitting).frame(width: 110)
    }
    .padding()
    .background(Camp.paper)
}
