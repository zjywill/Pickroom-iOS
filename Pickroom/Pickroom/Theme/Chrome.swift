import SwiftUI
import UIKit

// MARK: - Navigation bar

/// The camp navigation bar: round chunky buttons either side and a
/// rounded title (or any view) in the middle. Replaces the system bar
/// everywhere, sheets included.
struct CampNavigationBar<Leading: View, Center: View, Trailing: View>: ViewModifier {
    var background: Color
    var showsGrabber: Bool
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .campTabBarSpace()
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    if showsGrabber {
                        Capsule()
                            .fill(Camp.panelEdge)
                            .frame(width: 44, height: 6)
                            .padding(.top, 8)
                            .accessibilityHidden(true)
                    }
                    ZStack {
                        center()
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 60)
                        HStack {
                            leading()
                            Spacer()
                            trailing()
                        }
                    }
                    .frame(minHeight: 50)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                .background(background.ignoresSafeArea(edges: .top))
            }
    }
}

extension View {
    /// Camp bar with a text title.
    func campNavigationBar<Leading: View, Trailing: View>(
        _ title: String,
        background: Color = Camp.paper,
        showsGrabber: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) -> some View {
        modifier(CampNavigationBar(
            background: background,
            showsGrabber: showsGrabber,
            leading: leading,
            center: {
                Text(title)
                    .font(Camp.display(.headline, weight: .bold))
                    .foregroundStyle(Camp.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            },
            trailing: trailing
        ))
    }

    /// Camp bar with a custom centre view.
    func campNavigationBar<Leading: View, Center: View, Trailing: View>(
        background: Color = Camp.paper,
        showsGrabber: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder center: @escaping () -> Center,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(CampNavigationBar(
            background: background,
            showsGrabber: showsGrabber,
            leading: leading,
            center: center,
            trailing: trailing
        ))
    }

    /// Sheet chrome in the camp palette; the bar draws its own grabber.
    /// Sheets cover the tab bar, so they reserve no space for it.
    func campSheet() -> some View {
        self
            .environment(\.campTabBarInset, 0)
            .presentationBackground(Camp.sheet)
            .presentationCornerRadius(32)
            .presentationDragIndicator(.hidden)
    }
}

/// Round cream icon button for the bar: back, close, done.
struct CampBarButton: View {
    enum Kind {
        case back, close, done

        var symbol: String {
            switch self {
            case .back: "chevron.left"
            case .close: "xmark"
            case .done: "checkmark"
            }
        }

        var label: String {
            switch self {
            case .back: "Back"
            case .close: "Close"
            case .done: "Done"
            }
        }
    }

    let kind: Kind
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.symbol)
        }
        .buttonStyle(RoundChunkyButtonStyle(
            fill: kind == .done ? Camp.keep : Camp.cream,
            edge: kind == .done ? Camp.keepEdge : Camp.panelEdge,
            foreground: kind == .done ? .white : Camp.ink,
            size: 44
        ))
        .accessibilityLabel(accessibilityLabel ?? kind.label)
    }
}

/// Back button that appears only when the view was pushed, so the same
/// screen works as a tab root and as a pushed destination.
struct CampBackButtonIfPushed: View {
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if isPresented {
            CampBarButton(kind: .back) { dismiss() }
        }
    }
}

/// Hiding the system bar also disables edge-swipe back; this keeps it.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

// MARK: - Tab bar

enum RootTab: Hashable, CaseIterable {
    case home, triage, review

    var title: String {
        switch self {
        case .home: "Home"
        case .triage: "Triage"
        case .review: "Review"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .triage: "rectangle.stack.fill"
        case .review: "square.grid.2x2.fill"
        }
    }
}

/// Floating cream tab bar; the selected tab sits on a wood block.
struct CampTabBar: View {
    @Binding var selection: RootTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .bold))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(Camp.display(.caption, weight: .bold))
                    }
                    .foregroundStyle(selected ? .white : Camp.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Camp.wood)
                                .shadow(color: Camp.woodEdge, radius: 0, x: 0, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Camp.cream)
                .shadow(color: Camp.panelEdge, radius: 0, x: 0, y: 5)
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
    }
}

extension EnvironmentValues {
    /// Height of the floating camp tab bar, so screens can keep their
    /// content clear of it. Zero where there is no tab bar.
    @Entry var campTabBarInset: CGFloat = 0
}

extension View {
    /// Reserves bottom space for the floating tab bar. Applied by the
    /// camp navigation bar, so every screen gets it.
    func campTabBarSpace() -> some View {
        modifier(CampTabBarSpace())
    }
}

private struct CampTabBarSpace: ViewModifier {
    @Environment(\.campTabBarInset) private var inset

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: inset)
        }
    }
}

// MARK: - Loading

/// Three bouncing dots in place of the system spinner.
struct CampSpinner: View {
    var color: Color = Camp.wood
    @State private var bouncing = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .offset(y: bouncing ? -5 : 3)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever()
                            .delay(Double(index) * 0.15),
                        value: bouncing
                    )
            }
        }
        .frame(height: 20)
        .onAppear { bouncing = true }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// Full-screen loading state: the raccoon waiting, dots, a line.
struct CampLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Raccoon()
                .frame(width: 90)
            CampSpinner()
            Text(message)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Camp.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Camp.paper)
        .campTabBarSpace()
    }
}

// MARK: - Divider

/// Dashed tan rule, for use inside panels.
struct DashedDivider: View {
    var body: some View {
        Line()
            .stroke(Camp.panelEdge, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
            .frame(height: 2)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
