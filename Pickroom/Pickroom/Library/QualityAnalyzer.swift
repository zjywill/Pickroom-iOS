import Foundation
import Photos
import UIKit
import Vision
import PickroomCore

/// Stage A′ — per-asset quality analysis, independent of grouping.
///
/// Runs over a ~256 px rendition: faces first (VNDetectFaceRectangles),
/// then attention-based saliency when no face was found, then the
/// core `FailedFrameDetector` over the resulting luma plane. Focus is
/// always judged on the subject region; the network is never touched.
struct QualityAnalyzer: Sendable {
    let detector = FailedFrameDetector()

    /// Full analysis result for one asset.
    struct Result: Sendable {
        var quality: QualityAssessment
        var aestheticsScore: Double?
        var isUtility: Bool?
        var faceCaptureQuality: Double?
        var scoredFromStandIn: Bool
    }

    func analyze(image: CGImage, subjectIsFace: Bool, faceCaptureQuality: Double?) -> QualityAssessment {
        let plane = Self.lumaPlane(from: image)
        let metrics = detector.metrics(for: plane, subjectIsFace: subjectIsFace)
        return detector.classify(metrics)
    }

    /// Runs the whole quality + utility pipeline for one image.
    func analyzeFull(
        image: CGImage,
        runAesthetics: Bool = true
    ) async -> Result {
        async let faceTask = Self.faceObservations(for: image)
        async let saliencyTask = Self.saliencyRect(for: image)
        async let aestheticsTask = runAesthetics
            ? Self.aesthetics(for: image)
            : nil

        let faces = await faceTask
        let saliency = await saliencyTask
        let aesthetics = await aestheticsTask

        let subjectRect: SubjectRegion
        let subjectIsFace: Bool
        let faceQuality: Double?

        if let faceRect = faces.largest?.rect {
            // Measure sharpness on the face, and slightly enlarged —
            // hair and shoulders carry focus information too.
            subjectRect = faceRect.inset(-0.05).clamped
            subjectIsFace = true
            faceQuality = faces.minCaptureQuality
        } else if let saliencyRect = saliency {
            subjectRect = saliencyRect
            subjectIsFace = false
            faceQuality = nil
        } else {
            subjectRect = SubjectRegion(x: 0, y: 0, width: 1, height: 1)
            subjectIsFace = false
            faceQuality = nil
        }

        let plane = LumaPlane(
            width: planeWidth(image),
            height: planeHeight(image),
            samples: Self.lumaSamples(from: image),
            subjectRect: subjectRect
        )
        let metrics = detector.metrics(
            for: plane,
            subjectIsFace: subjectIsFace,
            faceCaptureQuality: faceQuality
        )
        let quality = detector.classify(metrics)

        return Result(
            quality: quality,
            aestheticsScore: aesthetics?.score,
            isUtility: aesthetics?.isUtility,
            faceCaptureQuality: faceQuality,
            scoredFromStandIn: false
        )
    }

    // MARK: - Luma conversion

    /// Converts a CGImage into the core's luma plane. Grayscale
    /// luminance, 0…255, no color — focus and exposure are luma
    /// phenomena.
    static func lumaPlane(from image: CGImage) -> LumaPlane {
        LumaPlane(
            width: image.width,
            height: image.height,
            samples: lumaSamples(from: image)
        )
    }

    static func lumaSamples(from image: CGImage) -> [Double] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)

        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            // Extremely unlikely; a zero plane classifies as
            // obviouslyBroken, which is the conservative direction.
            return [Double](repeating: 0, count: width * height)
        }
        return bytes.map(Double.init)
    }

    private func planeWidth(_ image: CGImage) -> Int { image.width }
    private func planeHeight(_ image: CGImage) -> Int { image.height }

    // MARK: - Vision helpers

    struct FaceResult: Sendable {
        var largest: (rect: SubjectRegion, quality: Double?)?
        var minCaptureQuality: Double?
    }

    static func faceObservations(for image: CGImage) async -> FaceResult {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try await handler.perform([faceRequest, qualityRequest])
        } catch {
            return FaceResult()
        }

        let faces = (faceRequest.results ?? []).map { face in
            SubjectRegion(
                x: face.boundingBox.origin.x,
                y: 1 - face.boundingBox.maxY, // Vision is bottom-left origin
                width: face.boundingBox.width,
                height: face.boundingBox.height
            )
        }
        let qualities = (qualityRequest.results ?? []).compactMap(\.faceCaptureQuality).map(Double.init)

        guard let largest = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return FaceResult(largest: nil, minCaptureQuality: nil)
        }
        return FaceResult(
            largest: (rect: largest, quality: qualities.min()),
            minCaptureQuality: qualities.min()
        )
    }

    static func saliencyRect(for image: CGImage) async -> SubjectRegion? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try await handler.perform([request])
        } catch {
            return nil
        }
        guard
            let observation = request.results?.first,
            let salient = observation.salientObjects?.first
        else { return nil }
        let box = salient.boundingBox
        return SubjectRegion(
            x: box.origin.x,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        )
    }

    struct AestheticsResult: Sendable {
        var score: Double
        var isUtility: Bool
    }

    /// `VNCalculateImageAestheticsScoresRequest` — iOS 18+ unconditional
    /// at this deployment target. `isUtility` is the best
    /// expired-utility classifier available (receipts, saved-from-chat
    /// images), on top of the authoritative screenshot subtypes.
    static func aesthetics(for image: CGImage) async -> AestheticsResult? {
        let request = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try await handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return AestheticsResult(
            score: Double(observation.overallScore),
            isUtility: observation.isUtility
        )
    }
}

private extension SubjectRegion {
    /// Negative inset grows the rect (Vision's inset only shrinks).
    func inset(_ fraction: Double) -> SubjectRegion {
        let dx = width * fraction
        let dy = height * fraction
        return SubjectRegion(
            x: x - dx,
            y: y - dy,
            width: width + 2 * dx,
            height: height + 2 * dy
        )
    }
}
