import Foundation

/// A feature print over one asset's ~256 px rendition, produced by
/// `VNGenerateImageFeaturePrintRequest` in the app layer.
///
/// Two pins are load-bearing and both are part of the cache key:
///
/// - `revision` — Revision 1 and Revision 2 prints are **incomparable**
///   (the Vision header lists comparing non-comparable prints as an error
///   case). An OS upgrade can invalidate the entire cache, which is why
///   recompute must be schedulable through `BGProcessingTask`, not run in
///   the foreground.
/// - `cropAndScaleOption` — different options yield incomparable prints.
public struct Fingerprint: Codable, Hashable, Sendable {
    public let revision: Int
    public let cropAndScaleOption: String
    public let vector: [Float]

    public init(revision: Int, cropAndScaleOption: String, vector: [Float]) {
        self.revision = revision
        self.cropAndScaleOption = cropAndScaleOption
        self.vector = vector
    }

    /// Whether two prints may be compared at all. Prints recorded under a
    /// different revision or crop-and-scale option are discarded and
    /// recomputed, never compared.
    public func isComparable(to other: Fingerprint) -> Bool {
        revision == other.revision && cropAndScaleOption == other.cropAndScaleOption
    }
}

/// Distance metric over feature prints, kept behind a protocol for
/// substitutability — not because a swap is planned. The app injects a
/// Vision-backed metric (reconstructing `VNFeaturePrintObservation` and
/// calling `computeDistance`); core ships Euclidean for tests.
public protocol FeaturePrintMetric: Sendable {
    /// Distance between two prints, or `nil` when they are not
    /// comparable.
    func distance(_ a: Fingerprint, _ b: Fingerprint) -> Double?
}

public struct EuclideanFeaturePrintMetric: FeaturePrintMetric {
    public init() {}

    public func distance(_ a: Fingerprint, _ b: Fingerprint) -> Double? {
        guard a.isComparable(to: b) else { return nil }
        guard a.vector.count == b.vector.count, !a.vector.isEmpty else { return nil }
        var total: Double = 0
        for i in 0..<a.vector.count {
            let d = Double(a.vector[i]) - Double(b.vector[i])
            total += d * d
        }
        return total.squareRoot()
    }
}

/// The currently pinned request parameters. Stored alongside the cache;
/// a cache entry recorded under different parameters is stale by
/// definition.
public struct FingerprintRequestParameters: Hashable, Codable, Sendable {
    public let revision: Int
    public let cropAndScaleOption: String

    public init(revision: Int, cropAndScaleOption: String) {
        self.revision = revision
        self.cropAndScaleOption = cropAndScaleOption
    }

    public func matches(_ fingerprint: Fingerprint) -> Bool {
        fingerprint.revision == revision && fingerprint.cropAndScaleOption == cropAndScaleOption
    }
}
