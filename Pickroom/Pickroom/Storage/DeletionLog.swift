import Foundation
import Photos
import PickroomCore

/// Records what the app deleted and when, so the "pending in Recently
/// Deleted" figure can be shown live. iOS exposes no Recently Deleted
/// album to third parties, so this log of our own commits is the honest
/// source: "N photos you deleted here are pending in Recently Deleted".
///
/// **Never empty Recently Deleted automatically** — that is the one
/// irreversible step and it belongs to the user. This type only
/// reports; it cannot delete.
struct DeletionRecord: Codable, Hashable, Sendable {
    var date: Date
    var assetKeys: [String]
}

actor DeletionLog {
    /// iOS keeps deleted photos for 30 days; pending means still
    /// recoverable.
    static let retention: TimeInterval = 30 * 24 * 3600

    private let fileURL: URL

    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appendingPathComponent("Pickroom", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        fileURL = support.appendingPathComponent("deletions.json")
    }

    private func load() -> [DeletionRecord] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let records = try? JSONDecoder().decode([DeletionRecord].self, from: data)
        else { return [] }
        return records
    }

    private func save(_ records: [DeletionRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Records a committed batch.
    func record(assetKeys: [String], date: Date = Date()) {
        var records = load()
        records.append(DeletionRecord(date: date, assetKeys: assetKeys))
        save(records)
    }

    /// How many photos deleted here are still pending in Recently
    /// Deleted, and when the oldest expires.
    func pending(now: Date = Date()) -> (count: Int, oldest: Date?) {
        let records = load()
        let pending = records.filter { now.timeIntervalSince($0.date) < Self.retention }
        let count = pending.reduce(0) { $0 + $1.assetKeys.count }
        let oldest = pending.map(\.date).min()
        return (count, oldest)
    }

    /// Total photos deleted through the app, all time — for the report.
    func totalDeleted() -> Int {
        load().reduce(0) { $0 + $1.assetKeys.count }
    }

    /// Purges expired records from disk.
    func prune(now: Date = Date()) {
        let records = load()
        let fresh = records.filter { now.timeIntervalSince($0.date) < Self.retention }
        if fresh.count != records.count {
            save(fresh)
        }
    }
}

/// Session and decision persistence: compact binary stores, one file
/// each. Tens of thousands of rows; JSON will not hold.
///
/// - `decisions.bin` + `decisions.journal`: key → decision. Each change
///   is appended to the journal (a few bytes per swipe, not a rewrite
///   of tens of thousands of rows), so a kill mid-session loses
///   nothing; the journal folds into the snapshot on launch and
///   whenever it grows past `journalCompactionThreshold`.
/// - `groups.bin`: group id → state, including permanent dismissals.
/// - `session.bin`: the exact card the user was on.
actor PersistenceStore {
    private let directory: URL
    private var decisions: [String: PhotoDecision]
    private var groupStates: [String: GroupState]
    private var session: StoredSession?
    private var journalEntryCount = 0

    /// Journal entries tolerated before folding into the snapshot.
    static let journalCompactionThreshold = 2_000

    struct StoredSession: Codable, Hashable, Sendable {
        var currentGroupID: String?
        var reviewedCount: Int
        var reviewedPhotoCount: Int
        var date: Date

        init(
            currentGroupID: String?,
            reviewedCount: Int,
            reviewedPhotoCount: Int,
            date: Date
        ) {
            self.currentGroupID = currentGroupID
            self.reviewedCount = reviewedCount
            self.reviewedPhotoCount = reviewedPhotoCount
            self.date = date
        }

        // Tolerates sessions recorded before reviewedPhotoCount existed.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentGroupID = try container.decodeIfPresent(String.self, forKey: .currentGroupID)
            reviewedCount = try container.decode(Int.self, forKey: .reviewedCount)
            reviewedPhotoCount = try container.decodeIfPresent(Int.self, forKey: .reviewedPhotoCount) ?? 0
            date = try container.decode(Date.self, forKey: .date)
        }
    }

    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appendingPathComponent("Pickroom", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        self.directory = support
        var loaded: [String: PhotoDecision] = Self.loadDictionary(
            support.appendingPathComponent("decisions.bin")
        ) ?? [:]
        let journalURL = support.appendingPathComponent("decisions.journal")
        let replayed = Self.replayJournal(at: journalURL, into: &loaded)
        decisions = loaded
        if replayed > 0 {
            // Fold the journal into the snapshot once per launch.
            try? Self.writeDictionary(loaded, to: support.appendingPathComponent("decisions.bin"))
            try? FileManager.default.removeItem(at: journalURL)
        }
        groupStates = Self.loadDictionary(
            support.appendingPathComponent("groups.bin")
        ) ?? [:]
        if
            let data = try? Data(
                contentsOf: support.appendingPathComponent("session.bin")
            ),
            let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        {
            session = stored
        } else {
            session = nil
        }
    }

    // MARK: - Decisions

    func loadDecisions() -> [String: PhotoDecision] { decisions }

    /// Every decision persists immediately; killing the app loses
    /// nothing.
    func saveDecision(key: String, decision: PhotoDecision) {
        decisions[key] = decision
        appendJournal([(key, decision.rawValue)])
    }

    func saveDecisions(_ updates: [String: PhotoDecision]) {
        guard !updates.isEmpty else { return }
        for (key, decision) in updates {
            decisions[key] = decision
        }
        appendJournal(updates.map { ($0.key, $0.value.rawValue) })
    }

    /// Undo and "keep all" may clear decisions for a group's members.
    func removeDecisions(keys: [String]) {
        guard !keys.isEmpty else { return }
        for key in keys {
            decisions[key] = nil
        }
        appendJournal(keys.map { ($0, "") })
    }

    /// Appends entries (an empty value is a removal) and syncs them to
    /// disk. Compacts into the snapshot when the journal gets long.
    private func appendJournal(_ entries: [(key: String, value: String)]) {
        var data = Data()
        for entry in entries {
            data.appendPrefixedString(entry.key)
            data.appendPrefixedString(entry.value)
        }
        let url = directory.appendingPathComponent("decisions.journal")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
        journalEntryCount += entries.count
        if journalEntryCount >= Self.journalCompactionThreshold {
            compactDecisions()
        }
    }

    private func compactDecisions() {
        let snapshot = directory.appendingPathComponent("decisions.bin")
        guard (try? Self.writeDictionary(decisions, to: snapshot)) != nil else { return }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("decisions.journal")
        )
        journalEntryCount = 0
    }

    /// Applies journal entries in order. A torn final entry (killed
    /// mid-write) is ignored; everything before it stands.
    private static func replayJournal(
        at url: URL,
        into decisions: inout [String: PhotoDecision]
    ) -> Int {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return 0 }
        var reader = BinaryReader(data)
        var count = 0
        while reader.remaining > 0 {
            guard
                let key = reader.readPrefixedString(),
                let raw = reader.readPrefixedString()
            else { break }
            decisions[key] = raw.isEmpty ? nil : PhotoDecision(rawValue: raw)
            count += 1
        }
        return count
    }

    // MARK: - Group states

    func loadGroupStates() -> [String: GroupState] { groupStates }

    func saveGroupState(id: String, state: GroupState) {
        groupStates[id] = state
        persistGroupStates()
    }

    private func persistGroupStates() {
        let url = directory.appendingPathComponent("groups.bin")
        try? Self.writeDictionary(groupStates, to: url)
    }

    // MARK: - Session

    func loadSession() -> StoredSession? { session }

    func saveSession(_ stored: StoredSession) {
        session = stored
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(
                to: directory.appendingPathComponent("session.bin"),
                options: .atomic
            )
        }
    }

    // MARK: - Binary dictionary codec
    //
    // Format per file: magic "PKD1", count UInt32, then per entry:
    // key length + UTF-8, value raw string (length + UTF-8).
    // Compact: tens of thousands of rows; JSON will not hold.

    private static let magic: [UInt8] = Array("PKD1".utf8)

    private static func loadDictionary<T: RawRepresentable & Codable>(
        _ url: URL
    ) -> [String: T]? where T.RawValue == String {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var reader = BinaryReader(data)
        guard
            let magic = reader.readBytes(4),
            magic == Self.magic,
            let count = reader.readUInt32()
        else { return nil }
        var result: [String: T] = [:]
        for _ in 0..<count {
            guard
                let key = reader.readPrefixedString(),
                let raw = reader.readPrefixedString()
            else { return nil }
            guard let value = T(rawValue: raw) else { continue }
            result[key] = value
        }
        return result
    }

    private static func writeDictionary<T: RawRepresentable & Codable>(
        _ dictionary: [String: T],
        to url: URL
    ) throws where T.RawValue == String {
        var data = Data(Self.magic)
        data.appendLE(UInt32(dictionary.count))
        for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
            data.appendPrefixedString(key)
            data.appendPrefixedString(value.rawValue)
        }
        try data.write(to: url, options: .atomic)
    }
}
