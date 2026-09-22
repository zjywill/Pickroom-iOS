import SwiftUI
import PhotosUI
import Photos
import PickroomCore

/// Phase 0's screen: which situation the user is in and what will
/// actually help — including the case where the honest answer is "flip
/// a switch in Settings, don't delete anything". Worth installing on
/// its own.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrolledPastHeader = false
    @State private var showingSituation = false
    /// The situation already explained. A different one (say iCloud
    /// Photos was turned on since) is explained again, once.
    @AppStorage("situationShown") private var situationShown = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                VStack(spacing: 18) {
                    triageSection
                    countsSection
                    pendingSection
                    privacySection
                }
                .padding(.horizontal, 16)
                .padding(.top, -28)
                .padding(.bottom, 32)
            }
        }
        .campTabBarSpace()
        .background(Camp.paper)
        .ignoresSafeArea(edges: .top)
        // Once the scene has scrolled away, paper over the status bar
        // so content doesn't run under the clock.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 200
        } action: { _, past in
            withAnimation(.easeOut(duration: 0.15)) { scrolledPastHeader = past }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Camp.paper
                .frame(height: 0)
                .background(Camp.paper.ignoresSafeArea(edges: .top))
                .opacity(scrolledPastHeader ? 1 : 0)
        }
        .toolbar(.hidden, for: .navigationBar)
        // The storage situation, told once as a dialog rather than a
        // panel that sits on Home forever.
        .campDialog(
            isPresented: $showingSituation,
            title: model.diagnosis.title,
            message: model.diagnosis.advice
                + "\n\nWith iCloud Photos on there is one library: deleting here deletes everywhere.",
            actions: situationActions
        )
        .onAppear(perform: showSituationIfNew)
        .onChange(of: model.isLoadingLibrary) { showSituationIfNew() }
        // Refresh the Recently Deleted figure on appear and on return
        // from Photos, rather than behind a pull-to-refresh spinner.
        .task {
            await model.refreshPendingFigure()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshPendingFigure() }
        }
    }

    // MARK: - Header

    /// Lake, sign, and the raccoon hiding in a bush. Decoration only.
    private var header: some View {
        LakeScene()
            .overlay(alignment: .top) {
                WoodSign(title: "Pickroom")
                    .padding(.top, 96)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottom) {
                    Raccoon()
                        .frame(width: 78)
                        .offset(y: -38)
                    Bush()
                        .frame(width: 130)
                }
                .padding(.bottom, 12)
            }
    }

    // MARK: - Sections

    private var situationActions: [CampDialogAction] {
        var actions: [CampDialogAction] = []
        if model.diagnosis == .iCloudFullCopies {
            actions.append(CampDialogAction(title: "Open Settings → Photos") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
        }
        actions.append(CampDialogAction(title: "Got it", role: actions.isEmpty ? .primary : .cancel))
        return actions
    }

    /// Once the library has loaded the diagnosis is final; show it if
    /// this situation hasn't been explained yet.
    private func showSituationIfNew() {
        guard model.canTriage, !model.isLoadingLibrary, !model.records.isEmpty else { return }
        let key = String(describing: model.diagnosis)
        guard situationShown != key else { return }
        situationShown = key
        showingSituation = true
    }

    private var triageSection: some View {
        VStack(spacing: 14) {
            NavigationLink {
                if let deck = model.deck {
                    DeckView(deck: deck)
                } else {
                    CampLoadingView(message: "Loading your library…")
                }
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start sorting")
                            .font(Camp.display(.title, weight: .semibold))
                        Text(model.workRemainingText)
                            .font(.subheadline.weight(.bold))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .heavy))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Camp.keepEdge))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChunkyButtonStyle(
                fill: Camp.keep,
                edge: Camp.keepEdge,
                cornerRadius: 24,
                horizontalPadding: 18,
                verticalPadding: 16
            ))

            Text("Nothing leaves your library until you commit.")
                .font(.footnote)
                .foregroundStyle(Camp.muted)
                .multilineTextAlignment(.center)

            scanPanel

            if model.powerGate.isPaused {
                HStack(spacing: 10) {
                    IconBadge(systemImage: "thermometer.medium", fill: Camp.failed, size: 30)
                    Text("Analysis paused — device is hot or in Low Power Mode")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Camp.ink)
                }
                .campPanel(padding: 14)
            }

            if let summary = model.lastSessionSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Camp.muted)
            }
        }
    }

    /// The library scan: live counts while analysing, otherwise when it
    /// last ran and a Rescan button. Saved results mean a rescan only
    /// analyses new and edited photos.
    private var scanPanel: some View {
        let analysis: AnalysisCoordinator = model.analysis
        let busy = model.isLoadingLibrary || model.isRescanning
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(systemImage: "sparkle.magnifyingglass", fill: Camp.later, foreground: Camp.laterInk, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    if analysis.isAnalysing {
                        Text(analysis.lastMessage ?? "Analysing on this device…")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Camp.ink)
                        Text("\(analysis.processedCount.formatted()) of \(analysis.pendingCount.formatted()) new photos")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Camp.muted)
                            .monospacedDigit()
                    } else if busy {
                        Text("Reading your library…")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Camp.ink)
                    } else {
                        Text("^[\(model.summary.totalAssets) item](inflect: true) scanned")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Camp.ink)
                            .monospacedDigit()
                        if let date = model.lastScanDate {
                            Text("Last scan \(date, format: .relative(presentation: .named))")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Camp.muted)
                        }
                    }
                }
                Spacer(minLength: 0)
                if analysis.isAnalysing {
                    Text(analysis.progress, format: .percent.precision(.fractionLength(0)))
                        .font(Camp.display(.callout, weight: .semibold))
                        .foregroundStyle(Camp.laterEdge)
                        .monospacedDigit()
                } else {
                    Button {
                        Task { await model.rescan() }
                    } label: {
                        if busy {
                            CampSpinner(color: .white)
                        } else {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(ChunkyButtonStyle(
                        fill: Camp.wood,
                        edge: Camp.woodEdge,
                        cornerRadius: 14,
                        font: Camp.display(.subheadline, weight: .semibold),
                        horizontalPadding: 14,
                        verticalPadding: 8
                    ))
                    .disabled(busy)
                    .accessibilityLabel("Rescan library")
                }
            }
            if analysis.isAnalysing {
                CampProgressBar(value: analysis.progress)
                Text("Results are saved as they come — you can leave and come back without starting over.")
                    .font(.caption)
                    .foregroundStyle(Camp.muted)
            }
        }
        .campPanel(padding: 14)
    }

    /// What the engine found: counts by category. Each tile opens the
    /// category as a grid to look through and act on.
    private var countsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's in your library")
                .font(Camp.display(.title3, weight: .semibold))
                .foregroundStyle(Camp.ink)
                .padding(.horizontal, 4)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 16
            ) {
                ForEach(LibraryCategory.allCases) { category in
                    NavigationLink {
                        LibraryCategoryView(category: category)
                    } label: {
                        tile(category)
                    }
                    .buttonStyle(TileButtonStyle())
                }
            }
        }
        .opacity(model.isLoadingLibrary ? 0.5 : 1)
    }

    private func tile(_ category: LibraryCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconBadge(systemImage: category.symbol, fill: category.color, size: 34)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(Camp.panelEdge)
            }
            Text(model.count(of: category).formatted())
                .font(Camp.display(.title, weight: .semibold))
                .foregroundStyle(Camp.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(tileCaption(category))
                .font(.footnote.weight(.bold))
                .foregroundStyle(Camp.muted)
                .multilineTextAlignment(.leading)
        }
        .campPanel(cornerRadius: 18, padding: 14)
        .accessibilityElement(children: .combine)
    }

    private func tileCaption(_ category: LibraryCategory) -> String {
        guard category == .videos else { return category.title }
        let total = model.totalSize(of: model.keys(in: .videos))
        return total > 0 ? "Videos · \(total.formatted(.byteCount(style: .file)))" : category.title
    }

    /// The live "pending in Recently Deleted" figure, with the link to
    /// Photos. Never emptied automatically.
    @ViewBuilder
    private var pendingSection: some View {
        if model.recentlyDeletedPending > 0 {
            infoRow(
                symbol: "trash.fill",
                color: Camp.wood,
                title: "\(model.recentlyDeletedPending.formatted()) photos pending in Recently Deleted",
                caption: "Space is not returned until it is emptied. That step stays yours — in the Photos app."
            )
        }
    }

    /// Say it in the UI: "automatically analyse my photos" is an
    /// alarming sentence without the on-device guarantee.
    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow(
                symbol: "lock.fill",
                color: Camp.keep,
                title: "All analysis happens on this device",
                caption: "No network request is ever made to group or score a photo. Nothing about your photos leaves your phone."
            )
            if model.accessState == .limited {
                Button("Manage limited selection") {
                    // presentLimitedLibraryPicker rather than nagging.
                    model.presentLimitedLibraryPicker()
                }
                .buttonStyle(.campPlain)
            }
        }
    }

    private func infoRow(symbol: String, color: Color, title: String, caption: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: symbol, fill: color, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Camp.ink)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(Camp.muted)
            }
        }
        .campPanel(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// The gate: not determined → explain and ask; denied → honest exit;
/// limited → work over the selection and offer the picker.
struct PermissionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Raccoon(mood: model.accessState == .denied ? .oops : .watching)
                .frame(width: 120)

            switch model.accessState {
            case .notDetermined:
                Text("Pickroom reads your photo library to surface photos with no reason to exist: blurred frames, bursts, expired screenshots, exact duplicates.")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Camp.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Text("Deletion needs full access and always asks again before anything leaves your library.")
                    .font(.footnote)
                    .foregroundStyle(Camp.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Allow photo access") {
                    Task { await model.requestAccess() }
                }
                .buttonStyle(.keep)

            case .denied:
                Text("Photo access is off. Pickroom can't work without it — it never uploads anything, and deletion always goes through the system confirmation.")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Camp.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .buttonStyle(.wood)

            case .limited, .authorized:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Camp.paper)
    }
}

/// A home tile presses down onto its edge like the other camp buttons.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.spring(duration: 0.12), value: configuration.isPressed)
    }
}
