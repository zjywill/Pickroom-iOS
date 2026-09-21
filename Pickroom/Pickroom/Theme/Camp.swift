import SwiftUI

/// The campground look: flat colour, warm paper, chunky buttons.
///
/// Colour carries the decision everywhere — green keeps, red removes,
/// amber waits, wood is neutral — so a glance at a button says what it
/// does before its label is read. The look is deliberately a skin: no
/// points, streaks or levels, because keeping a photo must never be
/// worth less than tossing one.
enum Camp {
    // Ground
    static let paper = Color(hex: 0xF3E6C8)
    static let cream = Color(hex: 0xFFFBF2)
    static let sheet = Color(hex: 0xFFF6E3)
    static let panelEdge = Color(hex: 0xE2CFA6)
    static let sand = Color(hex: 0xEADCBC)

    // Text
    static let ink = Color(hex: 0x3A2E26)
    static let muted = Color(hex: 0x7A6A55)
    static let forestInk = Color(hex: 0x24401F)
    static let mossInk = Color(hex: 0x35592D)

    // Scenery
    static let sky = Color(hex: 0xBFE3E8)
    static let lake = Color(hex: 0x5FB3C9)
    static let meadow = Color(hex: 0xB5D98F)
    static let meadowEdge = Color(hex: 0x8DB36A)
    static let grass = Color(hex: 0x9BC66B)

    // Decisions
    static let keep = Color(hex: 0x3A8A3F)
    static let keepEdge = Color(hex: 0x276A2C)
    static let toss = Color(hex: 0xC9482F)
    static let tossEdge = Color(hex: 0x9A3320)
    static let later = Color(hex: 0xF2B33D)
    static let laterEdge = Color(hex: 0xC98A1E)
    static let laterInk = Color(hex: 0x5A3A0A)
    static let wood = Color(hex: 0xA8683D)
    static let woodEdge = Color(hex: 0x7A4A2A)

    // Category badges
    static let failed = Color(hex: 0xD9613F)
    static let duplicate = Color(hex: 0x8E6FC4)
    static let screenshot = Color(hex: 0xE09A1F)
    static let recording = Color(hex: 0xD96E9A)
    static let stone = Color(hex: 0x8C8790)

    // Disabled controls: flat, faint, muted
    static let disabledFill = Color(hex: 0xFFFBF2).opacity(0.45)
    static let disabledInk = Color(hex: 0x3A2E26).opacity(0.3)

    /// Rounded display type, following Dynamic Type.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Buttons

/// A solid button sitting on a darker edge; pressing pushes it down
/// onto the edge.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color
    var edge: Color
    var foreground: Color = .white
    var cornerRadius: CGFloat = 20
    var font: Font = Camp.display(.headline)
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 13

    @Environment(\.isEnabled) private var isEnabled

    private let depth: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        // Disabled buttons lie flat: no edge, a faint cream fill, muted
        // ink. Fading the coloured button instead muddies it into the
        // background and reads as a stain, not as "not yet".
        let pressed = configuration.isPressed && isEnabled
        let lift: CGFloat = isEnabled ? (pressed ? 1 : depth) : 0
        configuration.label
            .font(font)
            .foregroundStyle(isEnabled ? foreground : Camp.disabledInk)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isEnabled ? fill : Camp.disabledFill)
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(edge)
                    .offset(y: lift)
                    .opacity(isEnabled ? 1 : 0)
            }
            .offset(y: depth - lift)
            .padding(.bottom, depth)
            .animation(.spring(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}

extension ButtonStyle where Self == ChunkyButtonStyle {
    static var keep: ChunkyButtonStyle { .init(fill: Camp.keep, edge: Camp.keepEdge) }
    static var toss: ChunkyButtonStyle { .init(fill: Camp.toss, edge: Camp.tossEdge) }
    static var later: ChunkyButtonStyle {
        .init(fill: Camp.later, edge: Camp.laterEdge, foreground: Camp.laterInk)
    }
    static var wood: ChunkyButtonStyle { .init(fill: Camp.wood, edge: Camp.woodEdge) }
    static var campPlain: ChunkyButtonStyle {
        .init(fill: Camp.cream, edge: Camp.panelEdge, foreground: Camp.ink)
    }
}

/// A round icon button with the same pressed-onto-edge behaviour, and
/// the same flat look when disabled.
struct RoundChunkyButtonStyle: ButtonStyle {
    var fill: Color
    var edge: Color
    var foreground: Color = .white
    var size: CGFloat = 46

    @Environment(\.isEnabled) private var isEnabled

    private let depth: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let lift: CGFloat = isEnabled ? (pressed ? 1 : depth) : 0
        configuration.label
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(isEnabled ? foreground : Camp.disabledInk)
            .frame(width: size, height: size)
            .background(Circle().fill(isEnabled ? fill : Camp.disabledFill))
            .background(
                Circle()
                    .fill(edge)
                    .offset(y: lift)
                    .opacity(isEnabled ? 1 : 0)
            )
            .offset(y: depth - lift)
            .padding(.bottom, depth)
            .animation(.spring(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}

// MARK: - Panels and labels

/// Cream card on paper with a soft tan edge. No outline, no gradient.
struct CampPanel: ViewModifier {
    var cornerRadius: CGFloat = 22
    var padding: CGFloat = 16
    var fill: Color = Camp.cream
    var edge: Color = Camp.panelEdge

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(color: edge, radius: 0, x: 0, y: 5)
            }
    }
}

extension View {
    func campPanel(
        cornerRadius: CGFloat = 22,
        padding: CGFloat = 16,
        fill: Color = Camp.cream,
        edge: Color = Camp.panelEdge
    ) -> some View {
        modifier(CampPanel(cornerRadius: cornerRadius, padding: padding, fill: fill, edge: edge))
    }
}

/// Small uppercase ribbon: the group kind on a card, a section label.
struct CampTag: View {
    let text: String
    var fill: Color = Camp.later
    var edge: Color = Camp.laterEdge
    var foreground: Color = Camp.laterInk

    var body: some View {
        Text(text.uppercased())
            .font(Camp.display(.caption, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill)
                    .shadow(color: edge, radius: 0, x: 0, y: 3)
            )
    }
}

/// A coloured disc holding an SF Symbol.
struct IconBadge: View {
    let systemImage: String
    let fill: Color
    var foreground: Color = .white
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .accessibilityHidden(true)
    }
}

/// A capsule progress track in the camp palette.
struct CampProgressBar: View {
    let value: Double
    var fill: Color = Camp.later
    var edge: Color = Camp.laterEdge
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Camp.sand)
                Capsule()
                    .fill(fill)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(edge).frame(height: height * 0.22)
                    }
                    .clipShape(Capsule())
                    .frame(width: max(height, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// The ✕ / ✓ disc on a thumbnail: red for marked, green for keeper.
struct DecisionMark: View {
    enum Kind { case marked, keeper, flagged }
    let kind: Kind
    var size: CGFloat = 22

    var body: some View {
        Group {
            switch kind {
            case .marked:
                disc(Image(systemName: "xmark"), fill: Camp.toss)
            case .keeper:
                disc(Image(systemName: "checkmark"), fill: Camp.keep)
            case .flagged:
                // The app's own "clearly bad" flag: an outline, so it
                // never reads as a decision the user made.
                Circle()
                    .strokeBorder(Camp.toss, lineWidth: 2.5)
                    .background(Circle().fill(Camp.cream))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func disc(_ image: Image, fill: Color) -> some View {
        image
            .font(.system(size: size * 0.5, weight: .black))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Camp.cream, lineWidth: 2))
    }
}

/// Pill-shaped segmented control in the camp palette.
struct CampSegmented<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(Camp.display(.subheadline, weight: .semibold))
                        .foregroundStyle(selected ? .white : Camp.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Camp.wood)
                                    .shadow(color: Camp.woodEdge, radius: 0, x: 0, y: 3)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .background(
            Capsule()
                .fill(Camp.cream)
                .shadow(color: Camp.panelEdge, radius: 0, x: 0, y: 4)
        )
    }
}
