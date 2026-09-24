import Foundation
import Observation
import BackgroundTasks
import Photos
import UIKit
import PickroomCore

/// Monitors thermals and Low Power Mode. Fingerprinting pauses at
/// `thermalState >= .serious` and in Low Power Mode and resumes when
/// they clear — a culling app that heats the phone gets deleted.
@MainActor
@Observable
final class PowerGate {
    private(set) var isThermallySerious = false
    private(set) var isLowPowerMode = false

    var isPaused: Bool { isThermallySerious || isLowPowerMode }

    private var observers: [NSObjectProtocol] = []

    init(processInfo: ProcessInfo = .processInfo) {
        isThermallySerious = processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        isLowPowerMode = processInfo.isLowPowerModeEnabled

        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let info = ProcessInfo.processInfo
            Task { @MainActor in
                self?.isThermallySerious =
                    info.thermalState == .serious || info.thermalState == .critical
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let info = ProcessInfo.processInfo
            Task { @MainActor in
                self?.isLowPowerMode = info.isLowPowerModeEnabled
            }
        })
    }

    // PowerGate lives for the app's lifetime; observers use [weak self]
    // and are never removed explicitly.
}

/// Orchestrates the analysis stages over the library:
///
/// - Stage A′: quality (failed-frame tiers, aesthetics, face capture)
///   over a 256 px rendition of every image — and the exact-duplicate
///   hash from that same rendition, so no second pass.
/// - Candidate metadata: adjustment data and EXIF exposure bias, only
///   for the near-duplicate and bracket candidates the guards affect.
/// - Stage B: feature prints for near-duplicate candidates only, cached
///   on disk with the revision guard.
///
/// Every stage pauses on thermal pressure and Low Power Mode, stops
/// when cancelled, and never touches the network (`AssetImageProvider`
/// enforces that on every request).
@MainActor
@Observable
final class AnalysisCoordinator {
    nonisolated static let backgroundTaskIdentifier = "com.junyizhang.pickroom.fingerprint"

    let powerGate: PowerGate
    private let imageProvider: AssetImageProvider
    private let fingerprinter = VisionFingerprinter()
    private let hasher = ContentHasher()
    private let storageDirectory: URL

    private(set) var isAnalysing = false
    /// 0…1 over the current analysis batch.
    private(set) var progress: Double = 0
    private(set) var lastMessage: String?
    /// Images analysed so far / images the current pass has to analyse.
    private(set) var processedCount = 0
    private(set) var pendingCount = 0

    /// Stage A′ results on disk, so a relaunch or rescan analyses only
    /// new and edited photos — on a 50,000-photo library that is the
    /// difference between minutes and hours. Loaded off the main
    /// thread on first use.
    private var qualityCache: QualityCache?
    private var qualityCacheDirty = false

    /// Loaded off the main thread on first use: on a big library these
    /// files are megabytes, and decoding them at launch froze the UI.
    private var fingerprintCache: FingerprintCache?
    private var metadataCache: CandidateMetadataCache?
    private var fingerprintCacheDirty = false
    private var fingerprintSave: Task<Void, Never>?

    init(
        powerGate: PowerGate,
        imageProvider: AssetImageProvider,
        storageDirectory: URL? = nil
    ) {
        self.powerGate = powerGate
        self.imageProvider = imageProvider
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory()
    }

    /// v2: builds up to 1.0 (6) cached prints taken from iCloud stand-in
    /// thumbnails, which cannot be told apart from real ones, so the old
    /// file is dropped and every print recomputed once.
    private var fingerprintCacheURL: URL {
        storageDirectory.appendingPathComponent("fingerprints-v2.bin")
    }

    private var legacyFingerprintCacheURL: URL {
        storageDirectory.appendingPathComponent("fingerprints.bin")
    }

    private var metadataCacheURL: URL {
        storageDirectory.appendingPathComponent("candidate-metadata.plist")
    }

    private func loadedFingerprintCache() async -> FingerprintCache {
        if let fingerprintCache { return fingerprintCache }
        let url = fingerprintCacheURL
        let legacyURL = legacyFingerprintCacheURL
        let loaded = await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: legacyURL)
            return FingerprintCache.load(from: url, parameters: VisionFingerprinter.parameters)
        }.value
        // Another stage may have loaded it while this one waited.
        if let fingerprintCache { return fingerprintCache }
        fingerprintCache = loaded
        return loaded
    }

    private func loadedMetadataCache() async -> CandidateMetadataCache {
        if let metadataCache { return metadataCache }
        let url = metadataCacheURL
        let loaded = await Task.detached(priority: .utility) {
            CandidateMetadataCache.load(from: url)
        }.value
        if let metadataCache { return metadataCache }
        metadataCache = loaded
        return loaded
    }

    private nonisolated static func defaultStorageDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("Pickroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Stage A′ (quality) + exact duplicates

    /// Images PhotoKit could not render locally this launch.
    private var unrenderableKeys: Set<String> = []

    private func needsQuality(_ record: AssetRecord) -> Bool {
        record.mediaType == .image && record.quality == nil && !unrenderableKeys.contains(record.key)
    }

    /// Whether any image still waits for the quality pass.
    func needsQualityPass(_ records: [AssetRecord]) -> Bool {
        records.contains(where: needsQuality)
    }

    /// Analyses quality for every image not yet analysed and returns the
    /// updated records. One 256 px render per asset serves the
    /// failed-frame tiers, aesthetics, face capture *and* the exact
    /// duplicate hash — no second pass over the library. Pauses on
    /// thermal pressure and Low Power Mode, and stops when cancelled.
    /// Every `checkpointInterval` images the partial result is handed to
    /// `checkpoint`, so the deck improves while a big library is still
    /// being analysed; the cache is written every `saveInterval`.
    func analyseQuality(
        records: [AssetRecord],
        checkpointInterval: Int = 1000,
        saveInterval: Int = 200,
        checkpoint: (([AssetRecord]) async -> Void)? = nil
    ) async -> [AssetRecord] {
        let pending = records.indices.filter { needsQuality(records[$0]) }
        guard !pending.isEmpty else { return records }
        isAnalysing = true
        progress = 0
        processedCount = 0
        pendingCount = pending.count
        lastMessage = nil
        defer {
            isAnalysing = false
            saveQualityCache()
        }
        if qualityCache == nil { qualityCache = await Self.loadQualityCache(from: qualityCacheURL) }

        var updated = records
        let analyzer = QualityAnalyzer()
        // Progress is observed by Home; publishing it for every photo
        // redraws the screen thousands of times on a big library.
        let progressStride = max(1, pending.count / 200)

        for (done, position) in pending.enumerated() {
            guard await waitWhilePaused("Paused — device is hot or in Low Power Mode") else {
                return updated
            }
            if lastMessage != nil { lastMessage = nil }
            let record = records[position]
            let identifier = Self.identifier(record)
            let rendition = await imageProvider.analysisRendition(for: identifier)
            if rendition == nil {
                // No local rendition at all: skipped until next launch
                // instead of retried by every rescan.
                unrenderableKeys.insert(record.key)
            }
            if let rendition {
                let result = await analyzer.analyzeFull(image: rendition)
                updated[position].quality = result.quality
                updated[position].aestheticsScore = result.aestheticsScore
                updated[position].isUtility = result.isUtility
                updated[position].faceCaptureQuality = result.faceCaptureQuality
                updated[position].scoredFromStandIn = AssetImageProvider.isStandIn(rendition)
                // A stand-in is a tiny, heavily compressed thumbnail:
                // different shots of the same scene at the same pixel
                // size decode to identical pixels, so its hash would
                // call them exact duplicates. Only a real rendition is
                // hashed.
                if updated[position].scoredFromStandIn {
                    updated[position].contentHash = nil
                } else {
                    let hasher = hasher
                    updated[position].contentHash = await Task.detached(priority: .utility) {
                        hasher.hash(
                            image: rendition,
                            pixelWidth: record.pixelWidth,
                            pixelHeight: record.pixelHeight
                        )
                    }.value
                }
                // A stand-in (degraded iCloud thumbnail) is re-scored once
                // the real rendition is local, so it is not saved.
                if !updated[position].scoredFromStandIn {
                    qualityCache?.store(updated[position])
                    qualityCacheDirty = true
                }
            }
            if (done + 1) % progressStride == 0 || done + 1 == pending.count {
                processedCount = done + 1
                progress = Double(done + 1) / Double(pending.count)
            }
            if (done + 1) % saveInterval == 0 { saveQualityCache() }
            if (done + 1) % checkpointInterval == 0, done + 1 < pending.count, let checkpoint {
                await checkpoint(updated)
            }
            if done % 25 == 0 {
                await Task.yield()
            }
        }
        return updated
    }

    /// Fills in Stage A′ results saved by earlier runs. Entries for
    /// photos no longer in the library are dropped.
    func applyCachedQuality(to records: [AssetRecord]) async -> [AssetRecord] {
        if qualityCache == nil { qualityCache = await Self.loadQualityCache(from: qualityCacheURL) }
        guard var cache = qualityCache else { return records }
        let applied = records.map { record -> AssetRecord in
            guard record.mediaType == .image, record.quality == nil else { return record }
            return cache.apply(to: record)
        }
        if cache.prune(retaining: Set(records.map(\.key))) {
            qualityCache = cache
            qualityCacheDirty = true
            saveQualityCache()
        }
        return applied
    }

    /// Forgets every saved result — the next pass analyses everything.
    func clearCaches() {
        qualityCache = QualityCache()
        qualityCacheDirty = true
        saveQualityCache()
    }

    private var qualityCacheURL: URL {
        storageDirectory.appendingPathComponent("quality.plist")
    }

    private nonisolated static func loadQualityCache(from url: URL) async -> QualityCache {
        await Task.detached(priority: .utility) { QualityCache.load(from: url) }.value
    }

    /// Encodes on the main actor (a value copy) and writes off it.
    private func saveQualityCache() {
        guard qualityCacheDirty, let cache = qualityCache else { return }
        qualityCacheDirty = false
        let url = qualityCacheURL
        Task.detached(priority: .utility) {
            try? cache.save(to: url)
        }
    }

    // MARK: - Candidate metadata (versions guard, bracket guard)

    /// Reads the two facts PhotoKit does not put on `PHAsset`, only for
    /// the assets the guards can affect:
    ///
    /// - adjustment data (the `versions` guard) for near-duplicate
    ///   candidates;
    /// - EXIF exposure bias (the bracket guard) for images shot within
    ///   the bracket window of a neighbour.
    ///
    /// Results are cached per key and modification date, so a relaunch
    /// does not re-read originals.
    func readCandidateMetadata(records: [AssetRecord]) async -> [AssetRecord] {
        let configuration = GroupEngineConfiguration()
        let versionKeys = Set(Self.candidateRecords(from: records, includeFingerprinted: true).map(\.key))
        let bracketKeys = Self.bracketCandidateKeys(records, configuration: configuration)
        let targets = records.indices.filter {
            versionKeys.contains(records[$0].key) || bracketKeys.contains(records[$0].key)
        }
        guard !targets.isEmpty else { return records }

        var updated = records
        var changed = false
        var metadataCache = await loadedMetadataCache()
        defer {
            self.metadataCache = metadataCache
            if changed { persistMetadataCache() }
        }
        for (done, position) in targets.enumerated() {
            guard await waitWhilePaused("Paused — device is hot or in Low Power Mode") else { break }
            let record = records[position]
            let identifier = Self.identifier(record)
            var entry = metadataCache.entry(for: record) ?? .init()

            if versionKeys.contains(record.key), entry.hasAdjustments == nil {
                // Reading asset resources is synchronous PhotoKit work;
                // thousands of candidates must not run it on the main
                // thread.
                entry.hasAdjustments = await Task.detached(priority: .utility) {
                    PhotoKitLibrary.hasAdjustments(identifier: identifier)
                }.value
                changed = true
            }
            if bracketKeys.contains(record.key), entry.exposureBiasChecked != true {
                entry.exposureBias = await PhotoKitLibrary.exposureBias(identifier: identifier)
                entry.exposureBiasChecked = true
                changed = true
            }
            metadataCache.set(entry, for: record)
            updated[position].isEditedVersion = entry.hasAdjustments ?? false
            updated[position].exposureBias = entry.exposureBias

            if done % 200 == 0 {
                if changed {
                    self.metadataCache = metadataCache
                    persistMetadataCache()
                }
                await Task.yield()
            }
        }
        return updated
    }

    /// Dated, non-utility images with a neighbour inside the bracket
    /// window — the only assets a bracket can contain.
    nonisolated static func bracketCandidateKeys(
        _ records: [AssetRecord],
        configuration: GroupEngineConfiguration
    ) -> Set<String> {
        let dated = records
            .filter { record in
                guard let date = record.capturedAt else { return false }
                return record.mediaType == .image
                    && !record.isExpiredUtilityByMetadata
                    && date > configuration.degenerateDateCutoff
            }
            .sorted { $0.capturedAt! < $1.capturedAt! }
        guard dated.count > 1 else { return [] }
        var keys = Set<String>()
        for index in 1..<dated.count {
            let gap = dated[index].capturedAt!.timeIntervalSince(dated[index - 1].capturedAt!)
            if gap <= configuration.bracketMaxGap {
                keys.insert(dated[index].key)
                keys.insert(dated[index - 1].key)
            }
        }
        return keys
    }

    // MARK: - Stage B (fingerprints)

    /// Fingerprints the near-duplicate candidate set and returns
    /// updated records. Candidates come from the core's Stage A output:
    /// only assets already placed close together in time, a few
    /// thousand in a 50,000-asset library — never the whole thing.
    func fingerprintCandidates(records: [AssetRecord]) async -> [AssetRecord] {
        isAnalysing = true
        progress = 0
        defer { isAnalysing = false }

        let candidates = candidateRecords(records)
        guard !candidates.isEmpty else { return records }
        _ = await loadedFingerprintCache()
        let progressStride = max(1, candidates.count / 200)

        var updated = records
        let byKey = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($1.key, $0)
        })
        var done = 0

        for record in candidates {
            // Thermal and Low Power throttling, pausable and resumable.
            guard await waitWhilePaused(
                "Fingerprinting paused — will resume when the device cools down"
            ) else { return persistAndReturn(updated) }

            // Cache first: same key, same modification date, same pinned
            // revision and crop option → never recomputed.
            if let cached = fingerprintCache?.fingerprint(
                forKey: record.key,
                modificationDate: record.modificationDate
            ) {
                if let position = byKey[record.key] {
                    updated[position].fingerprint = cached
                }
                done += 1
                if done % progressStride == 0 { progress = Double(done) / Double(candidates.count) }
                continue
            }

            let identifier = Self.identifier(record)
            guard let rendition = await imageProvider.analysisRendition(for: identifier) else {
                done += 1
                continue
            }
            do {
                let print = try await fingerprinter.fingerprint(for: rendition)
                // A print from a stand-in (iCloud-only) thumbnail serves
                // this session but is not saved: once the photo is on
                // the phone its modification date doesn't change, so a
                // cached stand-in print would never be replaced.
                if !AssetImageProvider.isStandIn(rendition) {
                    fingerprintCache?.upsert(
                        .init(
                            key: record.key,
                            modificationDate: record.modificationDate,
                            fingerprint: print
                        )
                    )
                    fingerprintCacheDirty = true
                }
                if let position = byKey[record.key] {
                    updated[position].fingerprint = print
                }
            } catch {
                // A failed fingerprint just means no near-duplicate
                // evidence for this asset; the engine treats missing
                // prints as "no group".
                lastMessage = "Fingerprint failed for one asset"
            }
            done += 1
            if done % progressStride == 0 { progress = Double(done) / Double(candidates.count) }
            // The whole table is rewritten on each save — every 10
            // prints made the total cost quadratic on a big library.
            if done % 250 == 0 { persistFingerprintCache() }
            if done % 10 == 0 { await Task.yield() }
        }
        return persistAndReturn(updated)
    }

    /// Stage A time-adjacency: assets that sit within the candidate
    /// window of another dated asset, excluding videos, screenshots and
    /// already-grouped bursts (bursts are grouped by identifier and
    /// don't need prints).
    nonisolated static func candidateRecords(
        from records: [AssetRecord],
        configuration: GroupEngineConfiguration = GroupEngineConfiguration(),
        includeFingerprinted: Bool = false
    ) -> [AssetRecord] {
        var candidateKeys = Set<String>()
        for (a, b) in CandidateSelection.candidatePairs(
            records,
            sessionGap: configuration.sessionGap,
            window: configuration.candidateWindow,
            dateCutoff: configuration.degenerateDateCutoff
        ) {
            candidateKeys.insert(records[a].key)
            candidateKeys.insert(records[b].key)
        }
        return records.filter { record in
            candidateKeys.contains(record.key)
                && record.mediaType == .image
                && !record.isExpiredUtilityByMetadata
                && record.burstIdentifier == nil
                && (includeFingerprinted || record.fingerprint == nil) // only the missing ones
        }
    }

    private func candidateRecords(_ records: [AssetRecord]) -> [AssetRecord] {
        Self.candidateRecords(from: records)
    }

    // MARK: - Helpers

    nonisolated static func identifier(_ record: AssetRecord) -> String {
        String(record.key.dropFirst("photos:".count))
    }

    /// Waits out thermal pressure and Low Power Mode. Returns `false`
    /// when the surrounding task was cancelled — the caller stops.
    private func waitWhilePaused(_ message: String) async -> Bool {
        while powerGate.isPaused {
            lastMessage = message
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return false }
        }
        return !Task.isCancelled
    }

    // MARK: - Cache persistence

    /// Both caches are value types: the copy is encoded and written off
    /// the main thread.
    private func persistMetadataCache() {
        guard let cache = metadataCache else { return }
        let url = metadataCacheURL
        Task.detached(priority: .utility) {
            try? cache.save(to: url)
        }
    }

    private func persistFingerprintCache() {
        guard fingerprintCacheDirty, let cache = fingerprintCache else { return }
        fingerprintCacheDirty = false
        let url = fingerprintCacheURL
        // Chained so an older, slower write can never land after a
        // newer one.
        let previous = fingerprintSave
        fingerprintSave = Task.detached(priority: .utility) {
            await previous?.value
            try? cache.save(to: url)
        }
    }

    private func persistAndReturn(_ records: [AssetRecord]) -> [AssetRecord] {
        progress = 1
        persistFingerprintCache()
        return records
    }

    // MARK: - Background task

    /// Registers the overnight `BGProcessingTask`: fingerprinting while
    /// charging, ideally on the charger overnight so no progress bar is
    /// ever seen. Call from the app's launch path.
    nonisolated static func registerBackgroundTask(handler: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // BGTask types predate Sendable; the task object is used
            // only for completion reporting on this serial path.
            nonisolated(unsafe) let completion = processingTask
            let work = Task {
                await handler()
                completion.setTaskCompleted(success: true)
            }
            processingTask.expirationHandler = {
                work.cancel()
            }
        }
    }

    nonisolated static func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling can fail (simulator, background refresh off);
            // foreground fingerprinting still works, just slower.
        }
    }
}

/// Per-asset facts read from resources and EXIF for the guards, keyed by
/// asset key and modification date so an edit invalidates them. Small:
/// only near-duplicate and bracket candidates are ever stored.
struct CandidateMetadataCache: Sendable {
    struct Entry: Codable, Hashable, Sendable {
        var hasAdjustments: Bool?
        var exposureBias: Double?
        var exposureBiasChecked: Bool?
    }

    private var entries: [String: Entry] = [:]

    static func load(from url: URL) -> CandidateMetadataCache {
        guard
            let data = try? Data(contentsOf: url),
            let entries = try? PropertyListDecoder().decode([String: Entry].self, from: data)
        else { return CandidateMetadataCache() }
        var cache = CandidateMetadataCache()
        cache.entries = entries
        return cache
    }

    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    func entry(for record: AssetRecord) -> Entry? {
        entries[Self.cacheKey(record)]
    }

    mutating func set(_ entry: Entry, for record: AssetRecord) {
        entries[Self.cacheKey(record)] = entry
    }

    private static func cacheKey(_ record: AssetRecord) -> String {
        "\(record.key)|\(record.modificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }
}

/// Stage A′ results per asset, keyed by asset key and modification date
/// so an edit re-analyses the photo.
struct QualityCache: Sendable {
    struct Entry: Codable, Sendable {
        var quality: QualityAssessment
        var aestheticsScore: Double?
        var isUtility: Bool?
        var faceCaptureQuality: Double?
        var scoredFromStandIn: Bool
        var contentHash: Data?
    }

    private var entries: [String: Entry] = [:]
    /// Asset key → cache key, for pruning.
    private var keyIndex: [String: String] = [:]

    static func load(from url: URL) -> QualityCache {
        guard
            let data = try? Data(contentsOf: url),
            let entries = try? PropertyListDecoder().decode([String: Entry].self, from: data)
        else { return QualityCache() }
        var cache = QualityCache()
        cache.entries = entries
        for cacheKey in entries.keys {
            if let bar = cacheKey.lastIndex(of: "|") {
                cache.keyIndex[String(cacheKey[..<bar])] = cacheKey
            }
        }
        return cache
    }

    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    mutating func store(_ record: AssetRecord) {
        guard let quality = record.quality else { return }
        let cacheKey = Self.cacheKey(record)
        if let old = keyIndex[record.key], old != cacheKey { entries[old] = nil }
        keyIndex[record.key] = cacheKey
        entries[cacheKey] = Entry(
            quality: quality,
            aestheticsScore: record.aestheticsScore,
            isUtility: record.isUtility,
            faceCaptureQuality: record.faceCaptureQuality,
            scoredFromStandIn: record.scoredFromStandIn,
            contentHash: record.contentHash
        )
    }

    func apply(to record: AssetRecord) -> AssetRecord {
        guard let entry = entries[Self.cacheKey(record)] else { return record }
        var filled = record
        filled.quality = entry.quality
        filled.aestheticsScore = entry.aestheticsScore
        filled.isUtility = entry.isUtility
        filled.faceCaptureQuality = entry.faceCaptureQuality
        filled.scoredFromStandIn = entry.scoredFromStandIn
        filled.contentHash = entry.contentHash
        return filled
    }

    /// Drops entries for assets not in `keys`. Returns whether anything
    /// was removed.
    mutating func prune(retaining keys: Set<String>) -> Bool {
        let gone = keyIndex.keys.filter { !keys.contains($0) }
        for key in gone {
            if let cacheKey = keyIndex.removeValue(forKey: key) { entries[cacheKey] = nil }
        }
        return !gone.isEmpty
    }

    var count: Int { entries.count }

    private static func cacheKey(_ record: AssetRecord) -> String {
        "\(record.key)|\(record.modificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }
}
