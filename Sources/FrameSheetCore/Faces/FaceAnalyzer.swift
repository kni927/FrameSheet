import CoreGraphics
import CoreVideo
import Foundation
import Vision

// Face detection, Lv1 (decision 16, §10): Apple Vision face rectangles on
// the scan pass's 720 px frames, behind `FaceAnalyzer` so a later analyzer
// (same-person grouping, Lv2) can take its place. Thresholds are applied
// when a frame is scanned, as in MoviePrint's `detectAllFaces`
// (app/utils/faceDetection.js, MIT, docs/licenses/MoviePrint-LICENSE).

/// A face as the analyzer found it, before the thresholds.
public struct DetectedFace: Sendable, Equatable {
    /// 0–1.
    public var confidence: Double
    /// Normalized to the frame (0–1), origin top left.
    public var box: CGRect

    public init(confidence: Double, box: CGRect) {
        self.confidence = confidence
        self.box = box
    }
}

/// Finds faces in an upright frame.
public protocol FaceAnalyzer: Sendable {
    /// A frame of the scan pass, valid only during the call.
    func detect(in frame: BGRAFrame) async throws -> [DetectedFace]
    /// A single decoded frame (the "these thumbs" scope).
    func detect(in image: CGImage) async throws -> [DetectedFace]
    /// Loads the model, so the first frame of a scan does not wait for it
    /// (first request in a process: up to 1.2 s; docs/v3-measurements.md).
    func warmUp() async
}

/// Vision's `DetectFaceRectanglesRequest` at its default revision (4 on
/// macOS 27; about 15 ms a frame at 720 px, docs/v3-measurements.md).
public final class VisionFaceAnalyzer: FaceAnalyzer {
    public static let shared = VisionFaceAnalyzer()

    public init() {}

    public func detect(in frame: BGRAFrame) async throws -> [DetectedFace] {
        // A copy the request owns: the scan's frame is reused once the
        // observer returns.
        let buffer = try Self.pixelBuffer(copying: frame)
        let observations = try await DetectFaceRectanglesRequest().perform(on: buffer)
        return observations.map(Self.face)
    }

    public func detect(in image: CGImage) async throws -> [DetectedFace] {
        let observations = try await DetectFaceRectanglesRequest().perform(on: image)
        return observations.map(Self.face)
    }

    public func warmUp() async {
        let side = 64
        let bytes = [UInt8](repeating: 0, count: side * side * 4)
        let frame = bytes.withUnsafeBytes {
            BGRAFrame(base: $0.baseAddress!, width: side, height: side, bytesPerRow: side * 4)
        }
        guard let buffer = try? Self.pixelBuffer(copying: frame) else { return }
        _ = try? await DetectFaceRectanglesRequest().perform(on: buffer)
    }

    /// Vision's box has its origin at the bottom left.
    private static func face(_ observation: FaceObservation) -> DetectedFace {
        let r = observation.boundingBox.cgRect
        return DetectedFace(
            confidence: Double(observation.confidence),
            box: CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height))
    }

    static func pixelBuffer(copying frame: BGRAFrame) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA, nil, &created)
        guard status == kCVReturnSuccess, let buffer = created else {
            throw DecodeError("Could not create a frame for face detection (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DecodeError("Could not create a frame for face detection")
        }
        let target = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = min(frame.width * 4, target, frame.bytesPerRow)
        for y in 0..<frame.height {
            (base + y * target).copyMemory(from: frame.base + y * frame.bytesPerRow, byteCount: rowBytes)
        }
        return buffer
    }
}

/// The face detection settings (§6), applied when a frame is scanned:
/// faces below either threshold are not stored ("takes effect on the next
/// scan").
public struct FaceThresholds: Codable, Sendable, Equatable {
    /// Confidence 0–100 (MoviePrint `FACE_CONFIDENCE_THRESHOLD`).
    public var confidence: Double
    /// Box height in % of the frame height, 0–100 (`FACE_SIZE_THRESHOLD`).
    public var size: Double

    public static let defaultConfidence = 70.0
    public static let defaultSize = 10.0

    public init(confidence: Double = FaceThresholds.defaultConfidence, size: Double = FaceThresholds.defaultSize) {
        self.confidence = confidence
        self.size = size
    }
}

/// What the face scan stores for one analyzed frame (§10).
public struct FaceFrame: Codable, Sendable, Equatable {
    public var frameNumber: Int
    /// Faces at or above the thresholds.
    public var faceCount: Int
    /// Size of the largest face (0 without faces).
    public var largestSize: Double
    /// Largest first.
    public var faces: [Face]

    public init(frameNumber: Int, faces: [Face]) {
        self.frameNumber = frameNumber
        self.faces = faces.sorted { $0.size > $1.size }
        faceCount = faces.count
        largestSize = self.faces.first?.size ?? 0
    }
}

public enum FaceDetection {
    /// The stored frame for what the analyzer found: confidence and size
    /// as whole percentages (MoviePrint `Math.round(score * 100)` and
    /// `Math.round(relativeBox.height * 100)`), the box rounded to four
    /// decimals, faces below a threshold dropped, largest first. Unlike
    /// MoviePrint, `faceCount` counts only the faces kept, so a frame whose
    /// faces all fall below the thresholds has none.
    public static func frame(_ frameNumber: Int, detected: [DetectedFace], thresholds: FaceThresholds) -> FaceFrame {
        func round4(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
        let faces = detected.compactMap { face -> Face? in
            let size = IntervalFrames.jsRound(Double(face.box.height) * 100)
            let confidence = IntervalFrames.jsRound(face.confidence * 100)
            guard size >= thresholds.size, confidence >= thresholds.confidence else { return nil }
            return Face(
                confidence: confidence, size: size, x: round4(face.box.minX), y: round4(face.box.minY),
                width: round4(face.box.width), height: round4(face.box.height))
        }
        return FaceFrame(frameNumber: frameNumber, faces: faces)
    }
}
