import Foundation

/// On-disk fingerprint cache. A compact binary table, not JSON: tens of
/// thousands of float vectors will not survive JSON round-trips at any
/// acceptable speed.
///
/// The revision guard is the point of this type: entries recorded under a
/// different request revision or crop-and-scale option are **discarded
/// and recomputed, never compared** (Vision prints are incomparable
/// across revisions; comparing them is an error case in the header).
public struct FingerprintCache: Sendable {
    public struct Entry: Hashable, Sendable {
        public let key: String
        public let modificationDate: Date?
        public let fingerprint: Fingerprint

        public init(key: String, modificationDate: Date?, fingerprint: Fingerprint) {
            self.key = key
            self.modificationDate = modificationDate
            self.fingerprint = fingerprint
        }
    }

    /// The pinned request parameters this cache instance serves.
    public let parameters: FingerprintRequestParameters

    private var entriesByAsset: [String: Entry] = [:]

    public init(parameters: FingerprintRequestParameters) {
        self.parameters = parameters
    }

    // MARK: - Access

    /// Returns the cached print for an asset when it is fresh: same
    /// revision, same crop-and-scale option, same modification date.
    /// Anything else returns `nil` — and counts as stale.
    public func fingerprint(forKey key: String, modificationDate: Date?) -> Fingerprint? {
        guard let entry = entriesByAsset[key] else { return nil }
        guard parameters.matches(entry.fingerprint) else { return nil }
        guard datesEqual(entry.modificationDate, modificationDate) else { return nil }
        return entry.fingerprint
    }

    public mutating func upsert(_ entry: Entry) {
        entriesByAsset[entry.key] = entry
    }

    /// Assets whose cache entries exist but are unusable under the
    /// current pinned parameters — they need recomputation.
    public func staleKeys() -> [String] {
        entriesByAsset
            .filter { !parameters.matches($0.value.fingerprint) }
            .map(\.key)
            .sorted()
    }

    public var count: Int { entriesByAsset.count }

    public var allEntries: [Entry] {
        entriesByAsset.values.sorted { $0.key < $1.key }
    }

    /// Drops entries for assets no longer present in the library.
    public mutating func prune(retainingKeys keys: Set<String>) {
        entriesByAsset = entriesByAsset.filter { keys.contains($0.key) }
    }

    private func datesEqual(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
    }

    // MARK: - Binary persistence

    /// File format: magic "PKFP" (4 bytes), version (UInt32 LE), count
    /// (UInt32 LE), then per entry: key length + UTF-8, modification
    /// date (Double, NaN when nil), revision (Int32), option length +
    /// UTF-8, vector count (UInt32) + Float32s.
    private static let magic: [UInt8] = Array("PKFP".utf8)
    private static let version: UInt32 = 1

    public func encoded() -> Data {
        var data = Data(Self.magic)
        data.appendLE(Self.version)
        let entries = allEntries
        data.appendLE(UInt32(entries.count))
        for entry in entries {
            data.appendPrefixedString(entry.key)
            if let date = entry.modificationDate {
                data.appendLE(date.timeIntervalSince1970)
            } else {
                data.appendLE(Double.nan)
            }
            data.appendLE(Int32(entry.fingerprint.revision))
            data.appendPrefixedString(entry.fingerprint.cropAndScaleOption)
            data.appendLE(UInt32(entry.fingerprint.vector.count))
            data.reserveCapacity(data.count + entry.fingerprint.vector.count * 4)
            for value in entry.fingerprint.vector {
                data.appendLE(value.bitPattern)
            }
        }
        return data
    }

    /// Loads from disk, ignoring everything recorded under different
    /// pinned parameters is *not* done here: stale entries are kept in
    /// memory so `staleKeys()` can drive recomputation, but
    /// `fingerprint(forKey:modificationDate:)` will never return them.
    public init?(data: Data, parameters: FingerprintRequestParameters) {
        var reader = BinaryReader(data)
        guard let magic = reader.readBytes(4), magic == Self.magic else { return nil }
        guard let version = reader.readUInt32(), version == Self.version else { return nil }
        guard let count = reader.readUInt32() else { return nil }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard
                let key = reader.readPrefixedString(),
                let timeInterval = reader.readDouble(),
                let revision = reader.readInt32(),
                let option = reader.readPrefixedString(),
                let vectorCount = reader.readUInt32()
            else { return nil }
            var vector: [Float] = []
            vector.reserveCapacity(Int(vectorCount))
            for _ in 0..<vectorCount {
                guard let bits = reader.readUInt32() else { return nil }
                vector.append(Float(bitPattern: bits))
            }
            let date = timeInterval.isNaN ? nil : Date(timeIntervalSince1970: timeInterval)
            entries[key] = Entry(
                key: key,
                modificationDate: date,
                fingerprint: Fingerprint(revision: Int(revision), cropAndScaleOption: option, vector: vector)
            )
        }
        self.parameters = parameters
        self.entriesByAsset = entries
    }

    public static func load(
        from url: URL,
        parameters: FingerprintRequestParameters
    ) -> FingerprintCache {
        guard
            let data = try? Data(contentsOf: url),
            let cache = FingerprintCache(data: data, parameters: parameters)
        else {
            return FingerprintCache(parameters: parameters)
        }
        return cache
    }

    public func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}

// MARK: - Little-endian binary helpers
//
// Shared with the app layer for its compact stores: public so both
// sides speak exactly the same byte format.

public struct BinaryReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    public var remaining: Int { data.count - offset }

    public mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard remaining >= count else { return nil }
        let start = data.startIndex.advanced(by: offset)
        let bytes = Array(data[start..<data.startIndex.advanced(by: offset + count)])
        offset += count
        return bytes
    }

    /// Reads without allocating: a fingerprint table is millions of
    /// these, and an array per value made loading take seconds.
    public mutating func readUInt32() -> UInt32? {
        readInteger(UInt32.self)
    }

    public mutating func readUInt64() -> UInt64? {
        readInteger(UInt64.self)
    }

    private mutating func readInteger<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        let start = data.startIndex + offset
        var value: T = 0
        for i in 0..<size {
            value |= T(data[start + i]) << (8 * i)
        }
        offset += size
        return value
    }

    public mutating func readInt32() -> Int32? {
        readUInt32().map(Int32.init(bitPattern:))
    }

    public mutating func readDouble() -> Double? {
        readUInt64().map { Double(bitPattern: $0) }
    }

    public mutating func readPrefixedString() -> String? {
        guard let length = readUInt32() else { return nil }
        guard let bytes = readBytes(Int(length)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Data {
    public mutating func appendLE(_ value: UInt32) {
        appendLE(integer: value)
    }

    public mutating func appendLE(_ value: UInt64) {
        appendLE(integer: value)
    }

    public mutating func appendLE(_ value: Int32) {
        appendLE(integer: UInt32(bitPattern: value))
    }

    public mutating func appendLE(_ value: Double) {
        appendLE(integer: value.bitPattern)
    }

    public mutating func appendLE(_ value: Float) {
        appendLE(integer: value.bitPattern)
    }

    public mutating func appendPrefixedString(_ string: String) {
        let bytes = Array(string.utf8)
        appendLE(UInt32(bytes.count))
        append(contentsOf: bytes)
    }

    private mutating func appendLE<T: FixedWidthInteger>(integer value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { raw in
            append(contentsOf: raw)
        }
    }
}

