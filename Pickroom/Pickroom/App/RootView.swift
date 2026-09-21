import SwiftUI
import PhotosUI
import Photos
import PickroomCore

/// Root: permission gate → the honest picture (home) → triage and
/// review. iPad gets a sidebar; iPhone gets a tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

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

    private var tabContent: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                if let deck = model.deck {
                    DeckView(deck: deck)
                } else {
                    ProgressView("Loading your library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .tabItem {
                Label("Triage", systemImage: "rectangle.stack")
            }

            NavigationStack {
                ReviewView()
            }
            .tabItem {
                Label("Review", systemImage: "square.grid.2x2")
            }
        }
    }

    private var sidebarContent: some View {
        NavigationSplitView {
            List {
                NavigationLink(destination: HomeView()) {
                    Label("Home", systemImage: "house")
                }
                NavigationLink(destination: deckDestination) {
                    Label("Triage", systemImage: "rectangle.stack")
                }
                NavigationLink(destination: ReviewView()) {
                    Label("Review", systemImage: "square.grid.2x2")
                }
            }
            .navigationTitle("Pickroom")
        } detail: {
            HomeView()
        }
    }

    @ViewBuilder
    private var deckDestination: some View {
        if let deck = model.deck {
            DeckView(deck: deck)
        } else {
            ProgressView("Loading your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
