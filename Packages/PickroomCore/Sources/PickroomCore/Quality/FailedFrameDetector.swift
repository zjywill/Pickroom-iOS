import Foundation

/// Group-independent failed-frame detection (Stage A′).
///
/// Every judgement here points at the bottom of the pile, never the top,
/// and every threshold is generous on survival: a missed bad frame costs
/// nothing, a false positive costs something irreplaceable. Focus is
/// judged on the **subject** region only — a shallow-DOF portrait with a
/// soft background is never flagged, because its subject is sharp.
public struct FailedFrameDetector: Sendable {
    public let thresholds: QualityThresholds

    public init(thresholds: QualityThresholds = QualityThresholds()) {
        self.thresholds = thresholds
    }

    /// Measures a luma plane and classifies it into a tier.
    public func assess(_ plane: LumaPlane) -> QualityAssessment {
        let metrics = measure(plane)
        return classify(metrics)
    }

    /// Classification from pre-computed metrics (so cached metrics from
    /// the app layer can be re-classified under different thresholds
    /// without re-rendering).
    public func classify(_ metrics: QualityMetrics) -> QualityAssessment {
        // Tier 1: degenerate frames. Not photographs of anything.
        // Solid black, solid white, a covered lens, a shutter inside a bag.
        if metrics.frameUniformity >= thresholds.brokenUniformity {
            return QualityAssessment(
                tier: .obviouslyBroken,
                metrics: metrics,
                reasons: ["Near-uniform frame — a covered lens or accidental press"]
            )
        }
        if metrics.clippedHighlights >= thresholds.brokenClipFraction {
            return QualityAssessment(
                tier: .obviouslyBroken,
                metrics: metrics,
                reasons: ["Almost entirely blown out"]
            )
        }
        if metrics.clippedShadows >= thresholds.brokenClipFraction {
            return QualityAssessment(
                tier: .obviouslyBroken,
                metrics: metrics,
                reasons: ["Almost entirely black"]
            )
        }

        // Tier 2: ordering signal only. Never a proposal, never bulk.
        // A soft subject means focus missed or the camera moved; a face
        // rectangle is the strongest evidence there was a subject at all.
        var reasons: [String] = []
        if metrics.subjectSharpness < thresholds.badSubjectSharpness {
            if metrics.subjectIsFace {
                reasons.append("Face is out of focus")
            } else {
                reasons.append("Out of focus or motion-blurred")
            }
        }
        if metrics.clippedHighlights >= thresholds.badClipFraction
            && metrics.clippedShadows >= thresholds.badClipFraction {
            reasons.append("Severely clipped exposure")
        }

        if !reasons.isEmpty {
            return QualityAssessment(tier: .probablyBad, metrics: metrics, reasons: reasons)
        }
        return QualityAssessment(tier: .ok, metrics: metrics, reasons: [])
    }

    /// Feature extraction over a luma plane.
    public func measure(_ plane: LumaPlane) -> QualityMetrics {
        let global = plane.samples
        let subject = subjectSamples(of: plane)

        return QualityMetrics(
            subjectSharpness: laplacianVariance(
                subject.samples,
                width: subject.width,
                height: subject.height
            ),
            globalSharpness: laplacianVariance(global, width: plane.width, height: plane.height),
            clippedHighlights: clipFraction(global, high: 252.5, low: nil),
            clippedShadows: clipFraction(global, high: nil, low: 2.5),
            frameUniformity: uniformity(global),
            subjectIsFace: false
        )
    }

    /// Sets `subjectIsFace` from the caller's face detection result.
    public func metrics(
        for plane: LumaPlane,
        subjectIsFace: Bool,
        faceCaptureQuality: Double? = nil
    ) -> QualityMetrics {
        var m = measure(plane)
        m = QualityMetrics(
            subjectSharpness: m.subjectSharpness,
            globalSharpness: m.globalSharpness,
            clippedHighlights: m.clippedHighlights,
            clippedShadows: m.clippedShadows,
            frameUniformity: m.frameUniformity,
            subjectIsFace: subjectIsFace
        )
        _ = faceCaptureQuality // carried separately on the record
        return m
    }

    // MARK: - Measurements

    private func subjectSamples(of plane: LumaPlane) -> (samples: [Double], width: Int, height: Int) {
        // The rect comes from the caller with face priority handled; the
        // detector itself only needs the pixels under it. Inset a little
        // to avoid boundary ringing from the crop.
        let rect = plane.subjectRect.clamped.inset(0.05)
        guard !rect.isEmpty else { return (plane.samples, plane.width, plane.height) }
        let x0 = Int((rect.x * Double(plane.width)).rounded())
        let y0 = Int((rect.y * Double(plane.height)).rounded())
        let x1 = min(Int(((rect.x + rect.width) * Double(plane.width)).rounded()), plane.width)
        let y1 = min(Int(((rect.y + rect.height) * Double(plane.height)).rounded()), plane.height)
        let width = x1 - x0
        let height = y1 - y0
        guard width >= 3, height >= 3 else { return (plane.samples, plane.width, plane.height) }

        var cropped: [Double] = []
        cropped.reserveCapacity(width * height)
        for y in y0..<y1 {
            for x in x0..<x1 {
                cropped.append(plane.samples[y * plane.width + x])
            }
        }
        return (cropped, width, height)
    }

    /// Variance of the discrete Laplacian — the standard focus measure.
    /// Interior pixels only, so plane edges don't skew small renders.
    func laplacianVariance(_ samples: [Double], width: Int, height: Int) -> Double {
        guard samples.count == width * height, width >= 3, height >= 3 else { return 0 }
        var values: [Double] = []
        values.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let laplacian = 4 * samples[i]
                    - samples[i - 1] - samples[i + 1]
                    - samples[i - width] - samples[i + width]
                values.append(laplacian)
            }
        }
        guard !values.isEmpty else { return 0 }
        return variance(values)
    }

    private func clipFraction(_ samples: [Double], high: Double?, low: Double?) -> Double {
        guard !samples.isEmpty else { return 0 }
        var clipped = 0
        for s in samples {
            if let high, s >= high { clipped += 1 }
            if let low, s <= low { clipped += 1 }
        }
        return Double(clipped) / Double(samples.count)
    }

    /// 1 − normalised standard deviation. Near 1 = essentially one value.
    private func uniformity(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 1 }
        let std = variance(samples).squareRoot()
        return 1.0 - min(std / 255.0, 1.0)
    }

    private func variance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var total = 0.0
        for v in values {
            let d = v - mean
            total += d * d
        }
        return total / Double(values.count)
    }
}
