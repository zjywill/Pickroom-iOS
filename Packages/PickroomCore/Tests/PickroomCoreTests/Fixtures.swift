import Foundation
import PickroomCore

/// Test fixtures shared by the core test suite.
enum Fixtures {
    static let base = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    /// A feature print with a fixed vector, far from other vectors.
    static func print(_ vector: [Float], revision: Int = 2, option: String = "scaleFill") -> Fingerprint {
        Fingerprint(revision: revision, cropAndScaleOption: option, vector: vector)
    }

    static func asset(
        _ key: String,
        capturedAt: Date? = base,
        mediaType: AssetMediaType = .image,
        isScreenshot: Bool = false,
        isScreenRecording: Bool = false,
        burstIdentifier: String? = nil,
        isBurstUserPick: Bool = false,
        isBurstAutoPick: Bool = false,
        sourceType: AssetSourceType = .userLibrary,
        isFavorite: Bool = false,
        exposureBias: Double? = nil,
        isEditedVersion: Bool = false,
        duration: TimeInterval? = nil,
        quality: QualityAssessment? = nil,
        isUtility: Bool? = nil,
        faceCaptureQuality: Double? = nil,
        aestheticsScore: Double? = nil,
        fingerprint: Fingerprint? = nil,
        contentHash: Data? = nil,
        fileName: String? = nil
    ) -> AssetRecord {
        AssetRecord(
            key: key,
            capturedAt: capturedAt,
            modificationDate: capturedAt,
            mediaType: mediaType,
            isScreenshot: isScreenshot,
            isScreenRecording: isScreenRecording,
            burstIdentifier: burstIdentifier,
            isBurstUserPick: isBurstUserPick,
            isBurstAutoPick: isBurstAutoPick,
            sourceType: sourceType,
            isFavorite: isFavorite,
            exposureBias: exposureBias,
            isEditedVersion: isEditedVersion,
            duration: duration,
            pixelWidth: 4032,
            pixelHeight: 3024,
            fileName: fileName ?? "\(key).heic",
            quality: quality,
            aestheticsScore: aestheticsScore,
            isUtility: isUtility,
            faceCaptureQuality: faceCaptureQuality,
            fingerprint: fingerprint,
            contentHash: contentHash
        )
    }

    // MARK: - Synthetic luma planes

    /// A sharp frame: high-frequency checkerboard detail everywhere.
    static func sharpPlane(size: Int = 64) -> LumaPlane {
        plane(size: size) { x, y in
            ((x + y) % 2 == 0) ? 210 : 40
        }
    }

    /// A soft frame: a slow gradient. Laplacian ≈ 0 everywhere, but the
    /// histogram has real spread, so it is not a uniform frame.
    static func softPlane(size: Int = 64) -> LumaPlane {
        plane(size: size) { x, _ in
            Double(x) / Double(size - 1) * 255
        }
    }

    /// The false positive that matters most: a shallow-DOF portrait —
    /// razor-sharp subject over a soft background. The subject rect is
    /// the face region; everything outside it drifts slowly.
    static func shallowDepthOfFieldPlane(size: Int = 64) -> LumaPlane {
        let face = SubjectRegion(x: 0.3, y: 0.2, width: 0.4, height: 0.5)
        let x0 = Int(face.x * Double(size))
        let x1 = Int((face.x + face.width) * Double(size))
        let y0 = Int(face.y * Double(size))
        let y1 = Int((face.y + face.height) * Double(size))
        return LumaPlane(
            width: size,
            height: size,
            samples: plane(size: size) { x, y in
                if x >= x0 && x < x1 && y >= y0 && y < y1 {
                    return ((x + y) % 2 == 0) ? 220 : 30 // sharp face
                }
                return Double(y) / Double(size - 1) * 180 // soft background
            }.samples,
            subjectRect: face
        )
    }

    static func solidPlane(value: Double, size: Int = 64) -> LumaPlane {
        .uniform(width: size, height: size, value: value)
    }

    private static func plane(
        size: Int,
        value: (Int, Int) -> Double
    ) -> LumaPlane {
        var samples: [Double] = []
        samples.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                samples.append(value(x, y))
            }
        }
        return LumaPlane(width: size, height: size, samples: samples)
    }
}
