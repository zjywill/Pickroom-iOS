import Foundation
import CryptoKit
import Vision
import Photos
import PickroomCore

/// Stage B: feature prints via `VNGenerateImageFeaturePrintRequest`,
/// behind pinned request parameters.
///
/// Revision 2 and `.scaleFill` are pinned and recorded in every cache
/// entry: prints from different revisions or crop-and-scale options are
/// incomparable, and a cached print under different parameters is
/// discarded and recomputed, never compared.
struct VisionFingerprinter: Sendable {
    /// The pinned parameters this build produces and the cache serves.
    static let parameters = FingerprintRequestParameters(
        revision: Int(VNGenerateImageFeaturePrintRequestRevision2),
        cropAndScaleOption: "scaleFill"
    )

    func fingerprint(for image: CGImage) async throws -> Fingerprint {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        request.revision = VNGenerateImageFeaturePrintRequestRevision2

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try await handler.perform([request])

        guard let observation = request.results?.first else {
            throw FingerprintingError.noObservation
        }
        return Self.fingerprint(from: observation)
    }

    /// Extracts the float vector from a live observation.
    static func fingerprint(from observation: VNFeaturePrintObservation) -> Fingerprint {
        let data = observation.data as Data
        let count = observation.elementCount
        var vector = [Float](repeating: 0, count: count)
        _ = vector.withUnsafeMutableBytes { raw in
            data.copyBytes(to: raw, from: 0..<count * MemoryLayout<Float>.size)
        }
        return Fingerprint(
            revision: parameters.revision,
            cropAndScaleOption: parameters.cropAndScaleOption,
            vector: vector
        )
    }

    enum FingerprintingError: Error {
        case noObservation
    }
}

/// Exact-duplicate hashing.
///
/// The plan's source of truth is "resource size + content hash"; iOS
/// offers no batched way to read original bytes, so the hash runs over
/// the deterministic on-device 256 px analysis rendition plus the source pixel
/// dimensions. Identical originals render identical renditions on the
/// same device, so byte-identical files still hash equal; re-encoded
/// copies from other devices are the near-duplicate engine's job, not
/// this one's. Guarded by dimensions so different photos never collide.
struct ContentHasher: Sendable {
    func hash(image: CGImage, pixelWidth: Int, pixelHeight: Int) -> Data {
        var digest = SHA256()
        withUnsafeBytes(of: pixelWidth.littleEndian) { digest.update(abusing: $0) }
        withUnsafeBytes(of: pixelHeight.littleEndian) { digest.update(abusing: $0) }

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            if let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        digest.update(data: Data(bytes))
        return Data(digest.finalize())
    }
}

private extension SHA256 {
    mutating func update(abusing bytes: UnsafeRawBufferPointer) {
        update(data: Data(bytes))
    }
}
