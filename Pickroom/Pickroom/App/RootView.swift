import SwiftUI
import PhotosUI
import Photos
import PickroomCore

/// Root: permission gate → the honest picture (home) → triage and
/// review. iPad gets a sidebar; iPhone gets a tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = .home
    @State private var tabBarHeight: CGFloat = 80

    var body: some View {
        Group {
            switch model.accessState {
            case .notDetermined, .denied:
                PermissionView()
            case .limited, .authorized:
                content
            }
        }
        .task {
            await model.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            // Access may have changed in Settings while away.
            guard phase == .active else { return }
            Task { await model.handleBecameActive() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            sidebarContent
        } else {
            tabContent
        }
    }

    /// The system tab bar is hidden; the camp bar floats over the tabs
    /// and publishes its height so each screen keeps content clear.
    private var tabContent: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView()
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(RootTab.home)

            NavigationStack {
                deckDestination
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(RootTab.triage)

            NavigationStack {
                ReviewView()
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(RootTab.review)
        }
        .environment(\.campTabBarInset, tabBarHeight)
        .environment(\.selectRootTab, { tab = $0 })
        .overlay(alignment: .bottom) {
            CampTabBar(selection: $tab)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabBarHeight = $0 }
        }
    }

    /// iPad: the same three places as a camp sidebar of wood blocks.
    private var sidebarContent: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pickroom")
                    .font(Camp.display(.largeTitle, weight: .bold))
                    .foregroundStyle(Camp.ink)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)
                ForEach(RootTab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ChunkyButtonStyle(
                        fill: item == tab ? Camp.wood : Camp.cream,
                        edge: item == tab ? Camp.woodEdge : Camp.panelEdge,
                        foreground: item == tab ? .white : Camp.ink
                    ))
                    .accessibilityAddTraits(item == tab ? .isSelected : [])
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Camp.paper)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack {
                switch tab {
                case .home: HomeView()
                case .triage: deckDestination
                case .review: ReviewView()
                }
            }
            .id(tab)
        }
        .environment(\.selectRootTab, { tab = $0 })
    }

    @ViewBuilder
    private var deckDestination: some View {
        if let deck = model.deck {
            DeckView(deck: deck)
        } else {
            CampLoadingView(message: "Loading your library…")
        }
    }
}
