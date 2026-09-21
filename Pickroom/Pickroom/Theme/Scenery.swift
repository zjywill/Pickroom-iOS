import SwiftUI

/// Flat illustrated backdrops. Drawn in a fixed design box and scaled
/// to width, so they stay crisp at any size and cost nothing to ship.
enum Scenery {
    fileprivate static func pine(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - h))
        path.addLine(to: CGPoint(x: x + h * 0.35, y: y - h * 0.45))
        path.addLine(to: CGPoint(x: x - h * 0.35, y: y - h * 0.45))
        path.closeSubpath()
        path.move(to: CGPoint(x: x, y: y - h * 0.7))
        path.addLine(to: CGPoint(x: x + h * 0.45, y: y))
        path.addLine(to: CGPoint(x: x - h * 0.45, y: y))
        path.closeSubpath()
        return path
    }

    fileprivate static func trunk(_ x: CGFloat, _ y: CGFloat) -> Path {
        Path(CGRect(x: x - 4, y: y - 2, width: 8, height: 10))
    }

    fileprivate static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    fileprivate static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }
}

/// Daytime lake, mountains and pines — the home screen's header.
/// Design box 390 × 320.
struct LakeScene: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 390
            context.scaleBy(x: scale, y: scale)

            context.fill(Path(CGRect(x: 0, y: 0, width: 390, height: 320)), with: .color(Camp.sky))
            context.fill(Scenery.ellipse(306, 66, 32, 32), with: .color(Color(hex: 0xFFE7A3)))
            for (cx, cy, rx, ry) in [(70.0, 64.0, 34.0, 12.0), (94, 56, 22, 12), (214, 40, 26, 9), (230, 34, 14, 8)] {
                context.fill(Scenery.ellipse(cx, cy, rx, ry), with: .color(.white))
            }

            context.fill(
                Scenery.polygon([(0, 190), (60, 122), (110, 170), (170, 98), (240, 175), (300, 126), (390, 186), (390, 320), (0, 320)]),
                with: .color(Color(hex: 0xA9CFC3))
            )
            context.fill(Scenery.polygon([(170, 98), (186, 117), (176, 115), (168, 123), (160, 115), (154, 117)]), with: .color(.white))
            context.fill(Scenery.polygon([(60, 122), (72, 136), (64, 134), (58, 140), (52, 134), (48, 136)]), with: .color(.white))

            var hills = Path()
            hills.move(to: CGPoint(x: 0, y: 222))
            hills.addQuadCurve(to: CGPoint(x: 170, y: 212), control: CGPoint(x: 80, y: 182))
            hills.addQuadCurve(to: CGPoint(x: 390, y: 206), control: CGPoint(x: 260, y: 242))
            hills.addLine(to: CGPoint(x: 390, y: 320))
            hills.addLine(to: CGPoint(x: 0, y: 320))
            context.fill(hills, with: .color(Color(hex: 0x7FB08A)))

            context.fill(Path(CGRect(x: 0, y: 232, width: 390, height: 30)), with: .color(Camp.lake))
            var ripples = Path()
            for (x, y, w) in [(150.0, 242.0, 50.0), (240, 252, 40), (110, 254, 22)] {
                ripples.move(to: CGPoint(x: x, y: y))
                ripples.addLine(to: CGPoint(x: x + w, y: y))
            }
            context.stroke(ripples, with: .color(Color(hex: 0xA6DCE8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            let back = Color(hex: 0x3F7D4E), front = Color(hex: 0x2C5E3A), bark = Color(hex: 0x7A4E30)
            for (x, y, h, color) in [(62.0, 254.0, 64.0, back), (24, 252, 92, front), (374, 256, 70, back), (338, 252, 98, front)] {
                context.fill(Scenery.pine(x, y, h), with: .color(color))
                context.fill(Scenery.trunk(x, y), with: .color(bark))
            }

            var grass = Path()
            grass.move(to: CGPoint(x: 0, y: 262))
            grass.addQuadCurve(to: CGPoint(x: 200, y: 262), control: CGPoint(x: 100, y: 248))
            grass.addQuadCurve(to: CGPoint(x: 390, y: 258), control: CGPoint(x: 300, y: 276))
            grass.addLine(to: CGPoint(x: 390, y: 320))
            grass.addLine(to: CGPoint(x: 0, y: 320))
            context.fill(grass, with: .color(Camp.grass))
        }
        .aspectRatio(390.0 / 320.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Sunset over the camp with a fire in the middle — the "all done"
/// screen. Design box 390 × 520; the fire sits at (200, 440).
struct DuskScene: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 390
            context.scaleBy(x: scale, y: scale)

            context.fill(Path(CGRect(x: 0, y: 0, width: 390, height: 520)), with: .color(Color(hex: 0xF4C28E)))
            context.fill(Path(CGRect(x: 0, y: 0, width: 390, height: 120)), with: .color(Color(hex: 0xE9A98A)))
            context.fill(Scenery.ellipse(110, 300, 56, 56), with: .color(Color(hex: 0xFFE1A8)))
            for (x, y, r) in [(300.0, 50.0, 2.5), (250, 80, 1.8), (350, 96, 2), (40, 60, 1.8)] {
                context.fill(Scenery.ellipse(x, y, r, r), with: .color(Color(hex: 0xFFF3DA)))
            }
            context.fill(
                Scenery.polygon([(0, 320), (70, 250), (130, 300), (200, 220), (280, 300), (340, 255), (390, 290), (390, 520), (0, 520)]),
                with: .color(Color(hex: 0xB78AA0))
            )

            var ridge = Path()
            ridge.move(to: CGPoint(x: 0, y: 360))
            ridge.addQuadCurve(to: CGPoint(x: 200, y: 352), control: CGPoint(x: 100, y: 320))
            ridge.addQuadCurve(to: CGPoint(x: 390, y: 340), control: CGPoint(x: 300, y: 384))
            ridge.addLine(to: CGPoint(x: 390, y: 520))
            ridge.addLine(to: CGPoint(x: 0, y: 520))
            context.fill(ridge, with: .color(Color(hex: 0x8A6A8E)))

            for (x, y, h, hex) in [(30.0, 404.0, 110.0, 0x4B3F5E), (360, 402, 120, 0x4B3F5E), (322, 404, 80, 0x5A4C6E)] {
                context.fill(Scenery.pine(x, y, h), with: .color(Color(hex: UInt32(hex))))
            }

            var ground = Path()
            ground.move(to: CGPoint(x: 0, y: 400))
            ground.addQuadCurve(to: CGPoint(x: 220, y: 398), control: CGPoint(x: 120, y: 384))
            ground.addQuadCurve(to: CGPoint(x: 390, y: 392), control: CGPoint(x: 320, y: 412))
            ground.addLine(to: CGPoint(x: 390, y: 520))
            ground.addLine(to: CGPoint(x: 0, y: 520))
            context.fill(ground, with: .color(Color(hex: 0x6E8B4E)))
            context.fill(Scenery.ellipse(200, 468, 120, 22), with: .color(Color(hex: 0xF7B267).opacity(0.35)))

            // Campfire
            context.translateBy(x: 200, y: 440)
            var logs = Path()
            logs.move(to: CGPoint(x: -38, y: 34)); logs.addLine(to: CGPoint(x: 38, y: 12))
            logs.move(to: CGPoint(x: -38, y: 12)); logs.addLine(to: CGPoint(x: 38, y: 34))
            context.stroke(logs, with: .color(Camp.woodEdge), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            context.fill(Self.flame(height: 58, width: 30), with: .color(Color(hex: 0xF07A3A)))
            context.fill(Self.flame(height: 30, width: 16), with: .color(Color(hex: 0xFFC857)))
        }
        .aspectRatio(390.0 / 520.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func flame(height: CGFloat, width: CGFloat) -> Path {
        let base: CGFloat = height > 40 ? 26 : 20
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -height))
        path.addQuadCurve(to: CGPoint(x: width * 0.73, y: 8), control: CGPoint(x: width, y: -height * 0.35))
        path.addQuadCurve(to: CGPoint(x: 0, y: base), control: CGPoint(x: width * 0.47, y: base))
        path.addQuadCurve(to: CGPoint(x: -width * 0.73, y: 8), control: CGPoint(x: -width * 0.47, y: base))
        path.addQuadCurve(to: CGPoint(x: 0, y: -height), control: CGPoint(x: -width, y: -height * 0.35))
        path.closeSubpath()
        return path
    }
}

/// Meadow backdrop for the deck: flat green with a few tufts and
/// flowers scattered by fraction of the frame, and a darker grass lip
/// along the bottom.
struct MeadowBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Camp.meadow))

            var tufts = Path()
            for (fx, fy) in [(0.08, 0.14), (0.83, 0.08), (0.15, 0.83), (0.87, 0.78), (0.51, 0.05), (0.05, 0.62), (0.95, 0.51)] {
                let x = size.width * fx, y = size.height * fy
                tufts.move(to: CGPoint(x: x, y: y))
                tufts.addQuadCurve(to: CGPoint(x: x + 12, y: y), control: CGPoint(x: x + 6, y: y - 10))
            }
            context.stroke(tufts, with: .color(Camp.grass), style: StrokeStyle(lineWidth: 4, lineCap: .round))

            for (fx, fy) in [(0.92, 0.66), (0.06, 0.36)] {
                let c = CGPoint(x: size.width * fx, y: size.height * fy)
                context.fill(Scenery.ellipse(c.x, c.y, 5, 5), with: .color(.white))
                context.fill(Scenery.ellipse(c.x, c.y, 2, 2), with: .color(Camp.later))
            }

            let lip = size.height - 92
            var ground = Path()
            ground.move(to: CGPoint(x: 0, y: lip + 8))
            ground.addQuadCurve(to: CGPoint(x: size.width / 2, y: lip + 6), control: CGPoint(x: size.width / 4, y: lip - 8))
            ground.addQuadCurve(to: CGPoint(x: size.width, y: lip), control: CGPoint(x: size.width * 0.75, y: lip + 16))
            ground.addLine(to: CGPoint(x: size.width, y: size.height))
            ground.addLine(to: CGPoint(x: 0, y: size.height))
            context.fill(ground, with: .color(Color(hex: 0x8DBF67)))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A bush for the raccoon to hide behind.
struct Bush: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 130
            context.scaleBy(x: scale, y: scale)
            context.fill(Scenery.ellipse(30, 40, 30, 24), with: .color(Color(hex: 0x5E9A4E)))
            context.fill(Scenery.ellipse(70, 32, 34, 28), with: .color(Color(hex: 0x6FA35A)))
            context.fill(Scenery.ellipse(108, 42, 26, 22), with: .color(Color(hex: 0x5E9A4E)))
        }
        .aspectRatio(130.0 / 64.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The hanging wooden "Pickroom" sign over the home scene.
struct WoodSign: View {
    let title: String

    var body: some View {
        VStack(spacing: -2) {
            Text(title)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0xFFF6E3))
                .shadow(color: Camp.woodEdge, radius: 0, x: 0, y: 3)
                .padding(.horizontal, 30)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Camp.wood)
                        .shadow(color: Camp.woodEdge, radius: 0, x: 0, y: 6)
                }
                .overlay(alignment: .topLeading) { nail.padding(10) }
                .overlay(alignment: .topTrailing) { nail.padding(10) }
                .rotationEffect(.degrees(-2))
                .zIndex(1)
            HStack(spacing: 70) {
                post
                post
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }

    private var nail: some View {
        Circle().fill(Color(hex: 0x5E3820)).frame(width: 7, height: 7)
    }

    private var post: some View {
        RoundedRectangle(cornerRadius: 3).fill(Camp.woodEdge).frame(width: 10, height: 104)
    }
}
