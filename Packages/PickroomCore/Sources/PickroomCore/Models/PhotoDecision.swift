import Foundation

/// Per-photo review state. Same states and semantics as the macOS app
/// (Pickroom `PhotoDecision`); decisions are keyed by `AssetRecord.key`
/// (`source.storageKey`), never by an ephemeral scan UUID.
public enum PhotoDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case unreviewed
    case pick
    case maybe
    case reject

    public var title: String {
        switch self {
        case .unreviewed: "Unreviewed"
        case .pick: "Pick"
        case .maybe: "Maybe"
        case .reject: "Reject"
        }
    }

    /// Whether the decision should count as "reviewed" when computing
    /// progress and group resolution.
    public var isReviewed: Bool { self != .unreviewed }
}
