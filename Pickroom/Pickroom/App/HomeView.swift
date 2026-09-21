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

    var body: some View {
        List {
            situationSection
            countsSection
            triageSection
            pendingSection
            privacySection
        }
        .navigationTitle("Pickroom")
        .refreshable {
            await model.refreshPendingFigure()
        }
    }

    // MARK: - Sections

    /// The three-way diagnosis, with the Optimise Storage advice where
    /// it applies and its honest limits.
    private var situationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.diagnosis.title, systemImage: "externaldrive")
                    .font(.headline)
                Text(model.diagnosis.advice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            if model.diagnosis == .iCloudFullCopies {
                Link(
                    "Open Settings → Photos",
                    destination: URL(string: UIApplication.openSettingsURLString)!
                )
                .font(.subheadline)
            }
        } header: {
            Text("Your situation")
        } footer: {
            Text("With iCloud Photos on there is one library: deleting here deletes everywhere, and Recently Deleted syncs too. There is no remove-from-this-phone-only.")
        }
    }

    /// What the engine found: counts by category, video counted as its
    /// own thing and otherwise left alone.
    private var countsSection: some View {
        Section("What's in your library") {
            row("Photos and videos", count: model.summary.totalAssets)
            row("Failed frames", count: model.summary.failedFrameCount)
            row("Exact duplicates", count: model.summary.exactDuplicateCount)
            row("Screenshots", count: model.summary.screenshotCount)
            row("Screen recordings", count: model.summary.screenRecordingCount)
            row("Videos (left alone)", count: model.summary.videoCount)
        }
        .opacity(model.isLoadingLibrary ? 0.5 : 1)
    }

    private func row(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var triageSection: some View {
        Section {
            NavigationLink {
                if let deck = model.deck {
                    DeckView(deck: deck)
                } else {
                    ProgressView("Loading your library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.workRemainingText)
                        .font(.headline)
                    Text("One gesture per decision. Nothing leaves your library until you commit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.analysis.isAnalysing {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        model.analysis.lastMessage ?? "Analysing on this device…",
                        systemImage: "sparkle.magnifyingglass"
                    )
                    .font(.subheadline)
                    ProgressView(value: model.analysis.progress)
                }
            }

            if model.powerGate.isPaused {
                Label(
                    "Analysis paused — device is hot or in Low Power Mode",
                    systemImage: "thermometer.medium"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Triage")
        } footer: {
            if let summary = model.lastSessionSummary {
                Text(summary)
            }
        }
    }

    /// The live "pending in Recently Deleted" figure, with the link to
    /// Photos. Never emptied automatically.
    private var pendingSection: some View {
        Section {
            if model.recentlyDeletedPending > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(model.recentlyDeletedPending.formatted()) photos pending in Recently Deleted",
                        systemImage: "trash"
                    )
                    .font(.subheadline)
                    Text("Space is not returned until it is emptied. That step stays yours — in the Photos app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Recently Deleted")
        }
    }

    /// Say it in the UI: "automatically analyse my photos" is an
    /// alarming sentence without the on-device guarantee.
    private var privacySection: some View {
        Section("Privacy") {
            Label(
                "All analysis happens on this device",
                systemImage: "lock.shield"
            )
            .font(.subheadline)
            Text("No network request is ever made to group or score a photo. Nothing about your photos leaves your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.accessState == .limited {
                Button("Manage limited selection") {
                    // presentLimitedLibraryPicker rather than nagging.
                    model.presentLimitedLibraryPicker()
                }
                .font(.subheadline)
            }
        }
    }
}

/// The gate: not determined → explain and ask; denied → honest exit;
/// limited → work over the selection and offer the picker.
struct PermissionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: model.accessState == .denied ? "lock.fill" : "photo.stack")
                .font(.system(size: 52))
                .foregroundStyle(model.accessState == .denied ? Color.red : Color.accentColor)

            switch model.accessState {
            case .notDetermined:
                Text("Pickroom reads your photo library to surface photos with no reason to exist: blurred frames, bursts, expired screenshots, exact duplicates.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Text("Deletion needs full access and always asks again before anything leaves your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Allow photo access") {
                    Task { await model.requestAccess() }
                }
                .buttonStyle(.borderedProminent)

            case .denied:
                Text("Photo access is off. Pickroom can't work without it — it never uploads anything, and deletion always goes through the system confirmation.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)

            case .limited, .authorized:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
