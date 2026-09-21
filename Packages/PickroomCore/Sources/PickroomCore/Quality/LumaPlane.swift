import Foundation

/// A grayscale rendition of one frame, 0…255 per sample, small enough to
/// analyse whole (the app layer renders ~256 px). Pure data: the app
/// converts a `CGImage`/pixel buffer to this, the core does the math.
public struct LumaPlane: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, count == width * height, values 0…255.
    public let samples: [Double]

    /// Subject region in normalized coordinates (0…1, x/y/width/height).
    /// Face rectangle when faces were detected, else the saliency crop,
    /// else the full frame.
    public let subjectRect: SubjectRegion

    public init(width: Int, height: Int, samples: [Double], subjectRect: SubjectRegion? = nil) {
        precondition(samples.count == width * height, "sample count must match dimensions")
        self.width = width
        self.height = height
        self.samples = samples
        self.subjectRect = subjectRect ?? SubjectRegion(x: 0, y: 0, width: 1, height: 1)
    }

    /// A plane of a single constant value — the solid black/white case.
    public static func uniform(
        width: Int = 64,
        height: Int = 64,
        value: Double
    ) -> LumaPlane {
        LumaPlane(
            width: width,
            height: height,
            samples: Array(repeating: value, count: width * height),
            subjectRect: nil
        )
    }
}

/// Rectangle in normalized image coordinates (0…1), origin top-left.
public struct SubjectRegion: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.width = width
        self.y = y
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Clamped to the unit square.
    public var clamped: SubjectRegion {
        let x0 = min(max(x, 0), 1)
        let y0 = min(max(y, 0), 1)
        let x1 = min(max(x + width, 0), 1)
        let y1 = min(max(y + height, 0), 1)
        return SubjectRegion(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }

    public func inset(_ fraction: Double) -> SubjectRegion {
        let dx = width * fraction
        let dy = height * fraction
        return SubjectRegion(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
}
