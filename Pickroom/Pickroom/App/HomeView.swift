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
    @State private var scrolledPastHeader = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                VStack(spacing: 18) {
                    situationSection
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
        .refreshable {
            await model.refreshPendingFigure()
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

    /// The three-way diagnosis, with the Optimise Storage advice where
    /// it applies and its honest limits.
    private var situationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CampTag(text: "Your situation")
            HStack(spacing: 12) {
                IconBadge(systemImage: "externaldrive.fill", fill: Camp.lake)
                Text(model.diagnosis.title)
                    .font(Camp.display(.title3, weight: .semibold))
                    .foregroundStyle(Camp.ink)
            }
            Text(model.diagnosis.advice)
                .font(.subheadline)
                .foregroundStyle(Camp.muted)

            if model.diagnosis == .iCloudFullCopies {
                Link(
                    "Open Settings → Photos",
                    destination: URL(string: UIApplication.openSettingsURLString)!
                )
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Camp.keep)
            }

            Divider()
                .overlay(Camp.panelEdge)
            Text("With iCloud Photos on there is one library: deleting here deletes everywhere, and Recently Deleted syncs too. There is no remove-from-this-phone-only.")
                .font(.footnote)
                .foregroundStyle(Camp.muted)
        }
        .campPanel(padding: 18)
    }

    private var triageSection: some View {
        VStack(spacing: 14) {
            NavigationLink {
                if let deck = model.deck {
                    DeckView(deck: deck)
                } else {
                    ProgressView("Loading your library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Text("One gesture per decision. Nothing leaves your library until you commit.")
                .font(.footnote)
                .foregroundStyle(Camp.muted)
                .multilineTextAlignment(.center)

            if model.analysis.isAnalysing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconBadge(systemImage: "sparkle.magnifyingglass", fill: Camp.later, foreground: Camp.laterInk, size: 30)
                        Text(model.analysis.lastMessage ?? "Analysing on this device…")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Camp.ink)
                        Spacer(minLength: 0)
                        Text(model.analysis.progress, format: .percent.precision(.fractionLength(0)))
                            .font(Camp.display(.callout, weight: .semibold))
                            .foregroundStyle(Camp.laterEdge)
                            .monospacedDigit()
                    }
                    CampProgressBar(value: model.analysis.progress)
                }
                .campPanel(padding: 14)
            }

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

    /// What the engine found: counts by category, video counted as its
    /// own thing and otherwise left alone.
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
                tile("Photos and videos", count: model.summary.totalAssets, symbol: "photo.fill", color: Camp.lake)
                tile("Failed frames", count: model.summary.failedFrameCount, symbol: "camera.metering.unknown", color: Camp.failed)
                tile("Exact duplicates", count: model.summary.exactDuplicateCount, symbol: "square.on.square.fill", color: Camp.duplicate)
                tile("Screenshots", count: model.summary.screenshotCount, symbol: "iphone", color: Camp.screenshot)
                tile("Screen recordings", count: model.summary.screenRecordingCount, symbol: "record.circle", color: Camp.recording)
                tile("Videos · left alone", count: model.summary.videoCount, symbol: "video.fill", color: Camp.stone)
            }
        }
        .opacity(model.isLoadingLibrary ? 0.5 : 1)
    }

    private func tile(_ title: String, count: Int, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(systemImage: symbol, fill: color, size: 34)
            Text(count.formatted())
                .font(Camp.display(.title, weight: .semibold))
                .foregroundStyle(Camp.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Camp.muted)
        }
        .campPanel(cornerRadius: 18, padding: 14)
        .accessibilityElement(children: .combine)
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
