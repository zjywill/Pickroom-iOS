import Foundation
import Photos
import UIKit
import Observation
import PickroomCore

/// Root model: owns the library, the analysis pipeline, the engine and
/// the deck, and the commit flow.
@MainActor
@Observable
final class AppModel {
    // Services
    let library = PhotoKitLibrary()
    let imageProvider = AssetImageProvider()
    let powerGate = PowerGate()
    private(set) var analysis: AnalysisCoordinator!
    let persistence = PersistenceStore()
    let deletionLog = DeletionLog()

    // Access
    private(set) var accessState: AccessState = .notDetermined

    // Library state
    private(set) var records: [AssetRecord] = [] {
        didSet {
            recordsByKey = Dictionary(
                records.map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    /// Record lookup by key — views never scan the whole library per row.
    private(set) var recordsByKey: [String: AssetRecord] = [:]
    private(set) var groups: [PhotoGroup] = []
    private(set) var summary = LibrarySummary()
    private(set) var isLoadingLibrary = false
    private(set) var diagnosis = StorageSituation.undetermined
    private(set) var recentlyDeletedPending = 0
    private(set) var lastSessionSummary: String?
    /// On-disk size of each video, for "biggest first". Filled in the
    /// background after each library load.
    private(set) var fileSizes: [String: Int64] = [:]
    private(set) var videoSizesReady = false
    /// When the library was last read from PhotoKit, shown on Home.
    private(set) var lastScanDate: Date? = UserDefaults.standard.object(forKey: "lastScanDate") as? Date
    private(set) var isRescanning = false

    // Commit
    private(set) var lastCommitReport: CommitReport?

    struct CommitReport: Hashable, Sendable {
        var deletedCount: Int
        var date: Date
        var storageBefore: DeviceStorageSnapshot
    }

    private var engine = GroupEngine()
    private var rebuildGeneration = 0

    init() {
        analysis = AnalysisCoordinator(
            powerGate: powerGate,
            imageProvider: imageProvider
        )
    }

    // MARK: - Launch / access

    private var isObservingLibrary = false
    private var sessionStarted = false
    private var analysisTask: Task<Void, Never>?

    /// Registers the overnight fingerprinting task. Must run while the
    /// app is still launching — `BGTaskScheduler` raises if a handler is
    /// registered after launch finishes, or registered twice — so the
    /// `App` initialiser calls this exactly once.
    static func registerBackgroundWork(for model: AppModel) {
        AnalysisCoordinator.registerBackgroundTask { [weak model] in
            await model?.runBackgroundFingerprinting()
        }
    }

    /// Launch path. Never asks for access by itself: with a
    /// not-determined status the permission screen explains first, and
    /// its button asks (`requestAccess()`).
    func bootstrap() async {
        accessState = library.currentAccessState()
        await startSessionIfPermitted()
    }

    /// The permission screen's button: the system prompt appears only
    /// after the app has said why it wants access.
    func requestAccess() async {
        accessState = await library.requestAccess()
        await startSessionIfPermitted()
    }

    /// Returning to the foreground — access may have changed in
    /// Settings (denied → allowed, or a new limited selection).
    func handleBecameActive() async {
        let previous = accessState
        accessState = library.currentAccessState()
        if accessState != previous {
            await startSessionIfPermitted()
        }
    }

    func refreshAccessState() {
        accessState = library.currentAccessState()
    }

    private func startSessionIfPermitted() async {
        guard canTriage else { return }
        if !isObservingLibrary {
            isObservingLibrary = true
            await library.observeChanges { [weak self] in
                Task { @MainActor in
                    self?.scheduleRescan()
                }
            }
        }
        if !sessionStarted {
            sessionStarted = true
            AnalysisCoordinator.scheduleBackgroundTask()
            await startSession()
        } else {
            await rescanLibrary()
        }
    }

    /// Offers the limited-library picker rather than nagging: over a
    /// limited selection the app triages exactly the selected assets.
    @MainActor
    func presentLimitedLibraryPicker() {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
            let root = scene.keyWindow?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    /// Full session bootstrap: diagnosis (Phase 0's honest picture),
    /// Stage A metadata scan, then the deck; analysis follows in the
    /// background.
    func startSession() async {
        guard canTriage else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        // Phase 0's screen is fed first: which situation the user is in
        // and what will actually help.
        async let diagnosisTask = StorageDiagnosis().diagnose(library: library)
        async let recordsTask = library.loadAssetRecords()
        async let pendingTask = deletionLog.pending()
        async let storedSessionTask = persistence.loadSession()

        records = await analysis.applyCachedQuality(to: await recordsTask)
        markScanned()
        let (pendingCount, _) = await pendingTask
        recentlyDeletedPending = pendingCount
        let storedSession = await storedSessionTask
        lastSessionSummary = DeckModel.sessionSummary(for: storedSession)

        let decisions = await persistence.loadDecisions()
        await rebuildDeck(decisions: decisions)
        diagnosis = await diagnosisTask
        await loadVideoSizes()

        restartAnalysis()
    }

    /// Re-runs the engine over the current records. Group state and
    /// decisions persist, so this is cheap and loses nothing.
    private func rebuildDeck(decisions: [String: PhotoDecision]) async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let groupStates = await persistence.loadGroupStates()
        // The engine is pure; on a library of thousands it takes long
        // enough to freeze the UI, so it runs off the main thread over
        // a snapshot.
        let engine = engine
        let records = records
        let (newGroups, newSummary) = await Task.detached(priority: .userInitiated) {
            engine.makeGroups(assets: records, groupStates: groupStates)
        }.value
        // A newer rebuild started while this one ran; its result wins.
        guard generation == rebuildGeneration else { return }
        groups = newGroups
        summary = newSummary

        if deck == nil {
            deck = DeckModel(
                groups: newGroups,
                records: records,
                decisions: decisions,
                persistence: persistence
            )
            await deck?.restoreSession()
            await deck?.rankCurrentCard()
        } else {
            deck?.reload(groups: newGroups, records: records)
        }
    }

    var deck: DeckModel?

    // MARK: - Analysis pipeline

    /// Cancels any running analysis and starts a fresh one over the
    /// current records. Only one pipeline ever runs at a time.
    private func restartAnalysis() {
        analysisTask?.cancel()
        // Utility priority: the UI (and the thumbnails it asks PhotoKit
        // for) always goes first.
        analysisTask = Task(priority: .utility) { [weak self] in
            await self?.runAnalysis()
        }
    }

    /// Quality (with the exact-duplicate hash from the same render),
    /// then byte proof for matching hashes, then the guards' candidate
    /// metadata, then fingerprints for the near-duplicate candidates.
    /// After each stage the results are
    /// merged into whatever the records are *now* — the library may
    /// have changed underneath — and the engine re-runs, so the deck
    /// improves incrementally.
    func runAnalysis() async {
        guard !records.isEmpty else { return }

        let analysed = await analysis.analyseQuality(records: records) { [weak self] partial in
            // Big libraries: let the deck improve while the pass runs.
            await self?.mergeAnalysis(partial)
        }
        guard !Task.isCancelled else { return }
        await mergeAnalysis(analysed)

        let verified = await analysis.verifyExactDuplicates(records: records)
        guard !Task.isCancelled else { return }
        await mergeAnalysis(verified)

        let withMetadata = await analysis.readCandidateMetadata(records: records)
        guard !Task.isCancelled else { return }
        await mergeAnalysis(withMetadata)

        let fingerprinted = await analysis.fingerprintCandidates(records: records)
        guard !Task.isCancelled else { return }
        await mergeAnalysis(fingerprinted)

        // Photos added while this pass ran.
        if analysis.needsQualityPass(records) {
            restartAnalysis()
        }
    }

    private var currentDecisions: [String: PhotoDecision] {
        deck?.decisions ?? [:]
    }

    /// Overnight fingerprinting through `BGProcessingTask`: the work
    /// happens on the charger and no progress bar is ever seen.
    func runBackgroundFingerprinting() async {
        guard canTriage else { return }
        if records.isEmpty {
            records = await library.loadAssetRecords()
        }
        let fingerprinted = await analysis.fingerprintCandidates(records: records)
        await mergeAnalysis(fingerprinted)
    }

    /// Copies analysis results onto the current records — never the
    /// other way round. A stage that started before a rescan must not
    /// resurrect deleted assets or overwrite fresher metadata, so only
    /// keys still present with the same modification date take the
    /// results.
    private func mergeAnalysis(_ analysed: [AssetRecord]) async {
        records = Self.merge(analysis: analysed, into: records)
        await rebuildDeck(decisions: currentDecisions)
    }

    nonisolated static func merge(
        analysis analysed: [AssetRecord],
        into current: [AssetRecord]
    ) -> [AssetRecord] {
        let byKey = Dictionary(
            analysed.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return current.map { record in
            guard
                let old = byKey[record.key],
                old.modificationDate == record.modificationDate
            else { return record }
            var merged = record
            merged.quality = old.quality ?? record.quality
            merged.aestheticsScore = old.aestheticsScore ?? record.aestheticsScore
            merged.isUtility = old.isUtility ?? record.isUtility
            merged.faceCaptureQuality = old.faceCaptureQuality ?? record.faceCaptureQuality
            merged.fingerprint = old.fingerprint ?? record.fingerprint
            merged.contentHash = old.contentHash ?? record.contentHash
            merged.originalHash = old.originalHash ?? record.originalHash
            merged.exposureBias = old.exposureBias ?? record.exposureBias
            merged.isEditedVersion = old.isEditedVersion || record.isEditedVersion
            merged.scoredFromStandIn = old.quality != nil ? old.scoredFromStandIn : record.scoredFromStandIn
            return merged
        }
    }

    // MARK: - Library changes

    private var pendingRescan: Task<Void, Never>?

    /// PhotoKit reports a change for every iCloud sync batch, favourite
    /// and edit — on a syncing library several a second. Each one used
    /// to re-read the whole library and restart analysis; now a burst
    /// of changes becomes one rescan once things go quiet.
    private func scheduleRescan() {
        pendingRescan?.cancel()
        pendingRescan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.rescanLibrary()
        }
    }

    private func rescanLibrary() async {
        guard canTriage else { return }
        let fresh = await library.loadAssetRecords()
        // Keep analysis results that are still valid (same
        // modification date); new or edited assets get analysed.
        records = await analysis.applyCachedQuality(to: Self.merge(analysis: records, into: fresh))
        markScanned()
        await rebuildDeck(decisions: currentDecisions)
        await loadVideoSizes()
        // A running pass picks up newcomers when it finishes; restarting
        // it would throw away its place.
        if !analysis.isAnalysing, analysis.needsQualityPass(records) {
            restartAnalysis()
        }
    }

    // MARK: - Sizes

    /// Reads the size of every video not yet measured. Videos are where
    /// the space is; photos are not worth a resource lookup each.
    private func loadVideoSizes() async {
        let missing = records
            .filter { $0.mediaType == .video && fileSizes[$0.key] == nil }
            .map { String($0.key.dropFirst("photos:".count)) }
        if !missing.isEmpty {
            let measured = await Task.detached(priority: .utility) {
                Self.fileSizes(identifiers: missing)
            }.value
            for (identifier, size) in measured {
                fileSizes["photos:\(identifier)"] = size
            }
            // Unmeasurable ones count as zero rather than being looked
            // up again on every rescan.
            for identifier in missing where measured[identifier] == nil {
                fileSizes["photos:\(identifier)"] = 0
            }
        }
        videoSizesReady = true
    }

    /// Sum of the original resources' sizes. PhotoKit has no public size
    /// API; `fileSize` on `PHAssetResource` is the long-standing way.
    nonisolated private static func fileSizes(identifiers: [String]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        assets.enumerateObjects { asset, _, _ in
            let total = PHAssetResource.assetResources(for: asset)
                .filter { $0.type == .video || $0.type == .fullSizeVideo || $0.type == .pairedVideo }
                .compactMap { ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value }
                .reduce(0, +)
            if total > 0 { sizes[asset.localIdentifier] = total }
        }
        return sizes
    }

    /// Known size of the given items; unmeasured ones count as zero.
    func totalSize(of keys: some Sequence<String>) -> Int64 {
        keys.reduce(0) { $0 + (fileSizes[$1] ?? 0) }
    }

    /// Home's Rescan: re-reads the library and analyses whatever is new
    /// or edited since last time. Saved results are reused, so this is
    /// cheap even on a huge library.
    func rescan() async {
        guard canTriage, !isRescanning else { return }
        isRescanning = true
        defer { isRescanning = false }
        await rescanLibrary()
        await refreshPendingFigure()
        if !analysis.isAnalysing { restartAnalysis() }
    }

    private func markScanned() {
        let now = Date()
        lastScanDate = now
        UserDefaults.standard.set(now, forKey: "lastScanDate")
    }

    // MARK: - Groups

    /// Permanently ignores a group from outside the deck (the review
    /// list). The deck drops it on the rebuild; nothing else restarts.
    func dismissGroup(id: String) async {
        await setGroupState(id: id, .dismissed)
    }

    /// Triage's "Start over": clears every mark and pick, brings decided
    /// sets back (and ignored ones, if asked), and starts a fresh deck
    /// from the first set. Nothing is deleted or restored in Photos.
    func startOver(includingIgnored: Bool) async {
        await deck?.settleWrites()
        await persistence.startOver(includingIgnored: includingIgnored)
        lastSessionSummary = nil
        deck = nil
        await rebuildDeck(decisions: [:])
    }

    /// A set decided (or reopened by undo) from Review → Sets. Resolved
    /// sets leave the Triage deck; pending ones come back to it.
    func setGroupState(id: String, _ state: GroupState) async {
        await persistence.saveGroupState(id: id, state: state)
        await rebuildDeck(decisions: currentDecisions)
    }

    // MARK: - Commit (batch delete)

    /// The deletion candidates: reject decisions over deletable assets
    /// only. `.iTunesSynced` and `.cloudShared` assets never enter this
    /// set — one undeletable asset fails the whole transaction.
    var commitCandidates: [String] {
        deck?.pendingRejects ?? []
    }

    /// Set when a commit failed for a reason other than the user
    /// declining the system confirmation.
    private(set) var lastCommitError: String?

    /// Executes the batch deletion. One `performChanges`, one system
    /// confirmation for the whole batch. Nothing is deleted during
    /// triage; this is the only code path that deletes anything.
    func commitDeletion() async -> Bool {
        lastCommitError = nil
        let candidates = commitCandidates
        guard !candidates.isEmpty else { return false }

        let identifiers = candidates.map { String($0.dropFirst("photos:".count)) }
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        guard assets.count > 0 else { return false }

        // Only assets that still exist AND are deletable enter the
        // batch — the pre-filter again, at the last moment, in case the
        // library changed since the candidate set was built.
        var deletable: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            if asset.sourceType == .typeUserLibrary {
                deletable.append(asset)
            }
        }
        guard !deletable.isEmpty else { return false }

        let storageBefore = DeviceStorageSnapshot.current()
        let deletedIdentifiers: [String] = deletable.map(\.localIdentifier)

        do {
            try await Self.deleteAssets(identifiers: deletedIdentifiers)
        } catch {
            // Declining the system confirmation is not a failure state,
            // just no deletion. Anything else is reported.
            let nsError = error as NSError
            let cancelled = nsError.domain == PHPhotosErrorDomain
                && nsError.code == PHPhotosError.userCancelled.rawValue
            if !cancelled {
                lastCommitError = "Nothing was deleted: \(error.localizedDescription)"
            }
            return false
        }

        let deletedKeys = deletedIdentifiers.map { "photos:\($0)" }
        await deletionLog.record(assetKeys: deletedKeys)
        deck?.clearDecisions(keys: deletedKeys)

        let (pendingCount, _) = await deletionLog.pending()
        recentlyDeletedPending = pendingCount
        lastCommitReport = CommitReport(
            deletedCount: deletedKeys.count,
            date: Date(),
            storageBefore: storageBefore
        )

        await rescanLibrary()
        return true
    }

    /// The PhotoKit transaction itself. `nonisolated` on purpose: PhotoKit
    /// runs the change block on its own queue, and a block formed inside
    /// this main-actor class would inherit main-actor isolation and trap
    /// at runtime the moment PhotoKit calls it.
    nonisolated private static func deleteAssets(identifiers: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    // MARK: - Home screen helpers

    var canTriage: Bool {
        accessState == .authorized || accessState == .limited
    }

    /// Count of photos with no reason to exist, per the engine —
    /// "work remaining", not bytes.
    var workRemainingText: String {
        let pending = groups.filter { $0.state == .pending }.count
        if pending == 0 { return "No sets waiting" }
        return "\(pending) sets to review"
    }

    func refreshPendingFigure() async {
        let (count, _) = await deletionLog.pending()
        recentlyDeletedPending = count
    }
}

/// The commit screen's wording — the one place in the app where the
/// language is deliberately heavy, because it must be unambiguous:
/// the user believes they are cleaning up their phone; they are in
/// fact changing their entire photo library.
enum CommitComposer {
    /// The headline for the confirmation sheet, matching what will
    /// actually happen under the detected storage situation.
    static func headline(
        count: Int,
        situation: StorageSituation
    ) -> String {
        let noun = count == 1 ? "photo" : "photos"
        let formatted = count.formatted()
        switch situation {
        case .iCloudOptimising:
            return "Delete \(formatted) \(noun) from iCloud and all your devices"
        case .iCloudFullCopies, .undetermined:
            // Whether iCloud Photos is on cannot be read from any public
            // API. When it has not been proven off, the wording must
            // not understate the reach of the deletion.
            return "Delete \(formatted) \(noun) from this iPhone — and from iCloud and all your devices if iCloud Photos is on"
        }
    }

    /// The supporting line: the 30-day grace period, always.
    static func supportingLine() -> String {
        "They move to Recently Deleted and are erased permanently after 30 days. Recently Deleted syncs across your devices too — there is one shared copy, not one per device."
    }
}
