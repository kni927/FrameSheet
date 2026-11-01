import Accelerate
import AVFoundation
import CoreImage

enum ScaleMode: String {
    /// Scaled by the reader's output settings.
    case reader
    /// Full-size output from the reader, scaled afterwards with vImage (BGRA only).
    case vimage
    /// Full-size output from the reader, scaled afterwards with Core Image.
    case coreimage
}

/// Scales full-size reader output after the fact, into buffers from a pool.
final class PostScaler {
    let mode: ScaleMode
    let pixelFormat: OSType
    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?
    private lazy var context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                    .cacheIntermediates: false])

    init(mode: ScaleMode, pixelFormat: OSType, width: Int, height: Int) throws {
        if mode == .vimage, pixelFormat != kCVPixelFormatType_32BGRA {
            throw SpikeError("vimage scaling is implemented for BGRA only")
        }
        self.mode = mode
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &output)
        guard let destination = output else { throw SpikeError("pixel buffer pool exhausted") }
        switch mode {
        case .vimage:
            CVPixelBufferLockBaseAddress(source, .readOnly)
            CVPixelBufferLockBaseAddress(destination, [])
            defer {
                CVPixelBufferUnlockBaseAddress(destination, [])
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
            }
            var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(source),
                                    height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                                    width: vImagePixelCount(CVPixelBufferGetWidth(source)),
                                    rowBytes: CVPixelBufferGetBytesPerRow(source))
            var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(destination),
                                    height: vImagePixelCount(height), width: vImagePixelCount(width),
                                    rowBytes: CVPixelBufferGetBytesPerRow(destination))
            let error = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            if error != kvImageNoError { throw SpikeError("vImageScale failed: \(error)") }
        case .coreimage:
            let sx = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(source))
            let sy = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(source))
            let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let target = CIRenderDestination(pixelBuffer: destination)
            try context.startTask(toRender: image, to: target).waitUntilCompleted()
        case .reader:
            return source
        }
        return destination
    }
}

/// Measurements 1 and 2: sequential decode, optionally with the shot metric.
func runDecode(_ args: Args) async throws {
    let path = try args.requireFile()
    let maxSide = args.int("max", 240)
    let format = args.string("format", "bgra")
    guard let mode = ScaleMode(rawValue: args.string("scale", "reader")) else {
        throw SpikeError("--scale must be reader, vimage or coreimage")
    }
    let withMetric = args.flag("metric")
    let seconds = args.double("seconds")
    let pixelFormat = format == "420f" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
    let (asset, track, info) = try await loadVideo(path)
    let (width, height) = scaledSize(info.width, info.height, maxSide: maxSide)
    log("decode: \(format) \(width)x\(height) scale=\(mode.rawValue) metric=\(withMetric) "
        + "range=\(seconds.map { "\($0)s" } ?? "whole file")")

    try await runRepeated(args.int("runs", 3)) { _ in
        let (reader, outputs) = try makeReader(asset, track, outputs: [
            ReaderOutput(pixelFormat: pixelFormat, size: mode == .reader && maxSide != 0 ? (width, height) : nil)
        ], seconds: seconds)
        let scaler = try PostScaler(mode: mode, pixelFormat: pixelFormat, width: width, height: height)
        var frames = 0
        var scaleTime = 0.0
        var metricTime = 0.0
        var checksum = 0.0
        var peak = footprintMB()
        let cpuStart = cpuSeconds()
        let systemStart = systemTicks()
        let start = now()
        while let sample = outputs[0].copyNextSampleBuffer() {
            try autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                frames += 1
                var target = buffer
                if mode != .reader {
                    let t = now()
                    target = try scaler.scale(buffer)
                    scaleTime += now() - t
                }
                if withMetric {
                    let t = now()
                    checksum += pixelFormat == kCVPixelFormatType_32BGRA ? meanV(target) : meanLuma(target)
                    metricTime += now() - t
                }
                if frames % 300 == 0 { peak = max(peak, footprintMB()) }
            }
        }
        try checkFinished(reader)
        let wall = now() - start
        var m = Metrics()
        m.set("frames", Double(frames))
        m.set("wall_s", wall)
        m.set("fps", Double(frames) / wall)
        if mode != .reader { m.set("scale_ms", scaleTime * 1000 / Double(frames)) }
        if withMetric {
            m.set("metric_ms", metricTime * 1000 / Double(frames))
            m.set("mean", checksum / Double(frames))
        }
        m.set("cpu_cores", (cpuSeconds() - cpuStart) / wall)
        m.set("system_cores", systemCores(since: systemStart))
        m.set("peak_mb", peak)
        return m
    }
}
