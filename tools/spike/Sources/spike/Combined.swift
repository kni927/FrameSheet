import Accelerate
import AVFoundation

/// Measurement 4: one pass that computes the shot metric at 240 px on every frame
/// and detects faces at 720 px on every Nth frame.
///
/// `--layout single` reads 720 px frames and scales each one to 240 px with vImage;
/// `--layout dual` adds a second 240 px output on the same reader.
func runCombined(_ args: Args) async throws {
    let path = try args.requireFile()
    let every = args.int("every", 10)
    let layout = args.string("layout", "single")
    let api = args.string("api", "swift")
    let device = args.string("device", "default")
    let seconds = args.double("seconds")
    let (asset, track, info) = try await loadVideo(path)
    let scan = scaledSize(info.width, info.height, maxSide: args.int("scan", 240))
    let face = scaledSize(info.width, info.height, maxSide: args.int("face", 720))
    log("combined: layout=\(layout) scan=\(scan.0)x\(scan.1) face=\(face.0)x\(face.1) every=\(every) "
        + "api=\(api) device=\(device) range=\(seconds.map { "\($0)s" } ?? "whole file")")

    let scanBytesPerRow = scan.0 * 4
    let scanPixels = UnsafeMutableRawPointer.allocate(byteCount: scanBytesPerRow * scan.1, alignment: 64)
    defer { scanPixels.deallocate() }

    try await runRepeated(args.int("runs", 3)) { _ in
        let detect = try makeFaceDetector(api: api, device: device, revision: 0)
        var outputs = [ReaderOutput(pixelFormat: kCVPixelFormatType_32BGRA, size: face)]
        if layout == "dual" { outputs.append(ReaderOutput(pixelFormat: kCVPixelFormatType_32BGRA, size: scan)) }
        let (reader, trackOutputs) = try makeReader(asset, track, outputs: outputs, seconds: seconds)
        var frames = 0
        var detections = 0
        var faces = 0
        var faceTime = 0.0
        var checksum = 0.0
        var peak = footprintMB()
        let cpuStart = cpuSeconds()
        let systemStart = systemTicks()
        let start = now()
        while let sample = trackOutputs[0].copyNextSampleBuffer() {
            guard let faceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if layout == "dual" {
                guard let scanSample = trackOutputs[1].copyNextSampleBuffer(),
                      let scanBuffer = CMSampleBufferGetImageBuffer(scanSample) else { break }
                checksum += meanV(scanBuffer)
            } else {
                CVPixelBufferLockBaseAddress(faceBuffer, .readOnly)
                var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(faceBuffer),
                                        height: vImagePixelCount(face.1), width: vImagePixelCount(face.0),
                                        rowBytes: CVPixelBufferGetBytesPerRow(faceBuffer))
                var dst = vImage_Buffer(data: scanPixels, height: vImagePixelCount(scan.1),
                                        width: vImagePixelCount(scan.0), rowBytes: scanBytesPerRow)
                vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
                CVPixelBufferUnlockBaseAddress(faceBuffer, .readOnly)
                checksum += meanV(base: scanPixels, width: scan.0, height: scan.1, bytesPerRow: scanBytesPerRow)
            }
            if frames % every == 0 {
                let t = now()
                faces += try await detect(faceBuffer)
                faceTime += now() - t
                detections += 1
            }
            frames += 1
            if frames % 300 == 0 { peak = max(peak, footprintMB()) }
            if frames % 36000 == 0 {
                log("  progress: \(frames) frames, \(String(format: "%.0f", now() - start)) s")
            }
        }
        try checkFinished(reader)
        let wall = now() - start
        var m = Metrics()
        m.set("frames", Double(frames))
        m.set("detections", Double(detections))
        m.set("wall_s", wall)
        m.set("fps", Double(frames) / wall)
        m.set("face_s", faceTime)
        m.set("scan_s", wall - faceTime)
        m.set("faces_per_detection", Double(faces) / Double(max(1, detections)))
        m.set("mean", checksum / Double(max(1, frames)))
        m.set("cpu_cores", (cpuSeconds() - cpuStart) / wall)
        m.set("system_cores", systemCores(since: systemStart))
        m.set("peak_mb", peak)
        return m
    }
}
