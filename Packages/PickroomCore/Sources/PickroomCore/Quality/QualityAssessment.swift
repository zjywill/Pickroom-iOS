import Foundation

/// Failed-frame tiers. The split is what makes the second tier
/// affordable: `obviouslyBroken` is bulk-safe, `probablyBad` is an
/// ordering signal only and never receives a deletion proposal — so a
/// false positive costs a swipe, not a photo.
public enum QualityTier: String, Codable, Hashable, Sendable {
    /// Near-zero variance across the entire frame: solid black, solid
    /// white, a covered lens, a shutter pressed inside a bag. Not a
    /// photograph of anything. Safe to sweep in bulk behind a review grid.
    case obviouslyBroken

    /// Out of focus, motion-blurred, severely clipped. Floated to the
    /// front of the deck and reviewed one card at a time.
    /// **No bulk action exists for this tier, at any threshold.**
    case probablyBad

    case ok
}

/// Numeric quality features measured on a ~256 px rendition.
public struct QualityMetrics: Codable, Hashable, Sendable {
    /// Laplacian variance measured on the subject region (face rectangle
    /// when faces were detected, else the saliency crop). The only focus
    /// signal that may flag a frame: global variance punishes shallow
    /// depth of field, where the subject is razor sharp against a soft
    /// background — the false positive that matters most.
    public let subjectSharpness: Double

    /// Laplacian variance over the whole frame. Reported, never used to
    /// flag.
    public let globalSharpness: Double

    /// Fraction of pixels at or above the highlight clip point.
    public let clippedHighlights: Double

    /// Fraction of pixels at or below the shadow clip point.
    public let clippedShadows: Double

    /// 0…1. How close the whole frame is to a single value; near 1 means
    /// a pocket shot or a covered lens.
    public let frameUniformity: Double

    /// True when the subject region came from a face rectangle — the
    /// strongest protection against flagging shallow-DOF portraits.
    public let subjectIsFace: Bool

    public init(
        subjectSharpness: Double,
        globalSharpness: Double,
        clippedHighlights: Double,
        clippedShadows: Double,
        frameUniformity: Double,
        subjectIsFace: Bool
    ) {
        self.subjectSharpness = subjectSharpness
        self.globalSharpness = globalSharpness
        self.clippedHighlights = clippedHighlights
        self.clippedShadows = clippedShadows
        self.frameUniformity = frameUniformity
        self.subjectIsFace = subjectIsFace
    }
}

/// Stage A′ result, attached to `AssetRecord.quality`.
public struct QualityAssessment: Codable, Hashable, Sendable {
    public let tier: QualityTier
    public let metrics: QualityMetrics
    /// Plain-language reasons for the tier, shown on the card.
    public let reasons: [String]

    public init(tier: QualityTier, metrics: QualityMetrics, reasons: [String]) {
        self.tier = tier
        self.metrics = metrics
        self.reasons = reasons
    }

    public var isBad: Bool { tier != .ok }

    /// Whether the failure judgement rests on exposure (clipping)
    /// rather than focus. Inside a burst, exposure-based badness is the
    /// signature of HDR/bracket source frames — an iPhone AEB burst
    /// keeps the −2 and +2 EV frames, which look blown out or black by
    /// design. PhotoKit exposes no exposure bias, so bursts never flag
    /// members on exposure evidence alone; focus failures still do.
    public var isExposureBased: Bool {
        reasons.contains {
            $0.contains("blown out") || $0.contains("black") || $0.contains("clipped")
        }
    }
}

/// Thresholds for failed-frame detection. Provisional defaults; the
/// split between tiers is the load-bearing design, the exact numbers are
/// calibration constants (§11: calibrated against real libraries, not
/// guessed — these are the starting points).
public struct QualityThresholds: Hashable, Sendable {
    /// Frame uniformity above this is `obviouslyBroken`
    /// (variance-wise: std deviation below `1/uniformityScale`).
    public var brokenUniformity: Double

    /// Highlight/shadow clipping fraction above this is `obviouslyBroken`
    /// (solid black / solid white frames).
    public var brokenClipFraction: Double

    /// Subject-region Laplacian variance (0–255 scale, 256 px rendition)
    /// below this is `probablyBad`.
    public var badSubjectSharpness: Double

    /// Both-end severe clipping above this is `probablyBad`.
    public var badClipFraction: Double

    public init(
        brokenUniformity: Double = 0.995,
        brokenClipFraction: Double = 0.97,
        badSubjectSharpness: Double = 12.0,
        badClipFraction: Double = 0.15
    ) {
        self.brokenUniformity = brokenUniformity
        self.brokenClipFraction = brokenClipFraction
        self.badSubjectSharpness = badSubjectSharpness
        self.badClipFraction = badClipFraction
    }
}
