import AVFoundation
import CoreML
import Vision

func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: "cpu"
    case .gpu: "gpu"
    case .neuralEngine: "ane"
    @unknown default: "\(device)"
    }
}

private func pick(_ name: String, from devices: [MLComputeDevice]?) throws -> MLComputeDevice? {
    if name == "default" { return nil }
    guard let device = devices?.first(where: { deviceName($0) == name }) else {
        throw SpikeError("device \(name) is not supported by this request")
    }
    return device
}

private func describe<Stage>(_ devices: [Stage: [MLComputeDevice]]) -> String {
    devices.map { stage, list in "\(stage): \(list.map(deviceName).joined(separator: ","))" }
        .sorted().joined(separator: "; ")
}

/// Prints the revisions and compute devices each face-rectangle API offers.
func printFaceDevices() {
    let swiftRequest = DetectFaceRectanglesRequest()
    log("swift DetectFaceRectanglesRequest: default \(swiftRequest.revision), supported "
        + "\(DetectFaceRectanglesRequest.supportedRevisions), devices \(describe(swiftRequest.supportedComputeStageDevices))")
    let vnRequest = VNDetectFaceRectanglesRequest()
    let vnDevices = (try? vnRequest.supportedComputeStageDevices) ?? [:]
    log("VNDetectFaceRectanglesRequest: default revision \(vnRequest.revision), supported "
        + "\(Array(VNDetectFaceRectanglesRequest.supportedRevisions)), devices \(describe(vnDevices))")
    log("all compute devices: \(MLComputeDevice.allComputeDevices.map(deviceName).joined(separator: ","))")
}

/// Returns a detector closure that reports the number of faces found in a frame.
func makeFaceDetector(api: String, device: String, revision: Int) throws -> (CVPixelBuffer) async throws -> Int {
    switch api {
    case "swift":
        var request = DetectFaceRectanglesRequest(revision == 3 ? .revision3 : revision == 4 ? .revision4 : nil)
        try request.setComputeDevice(pick(device, from: request.supportedComputeStageDevices[.main]), for: .main)
        let configured = request
        return { buffer in try await configured.perform(on: buffer).count }
    case "vn":
        let request = VNDetectFaceRectanglesRequest()
        if revision != 0 { request.revision = revision }
        let devices = try request.supportedComputeStageDevices[.main]
        request.setComputeDevice(try pick(device, from: devices), for: .main)
        return { buffer in
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            try handler.perform([request])
            return request.results?.count ?? 0
        }
    default:
        throw SpikeError("--api must be swift or vn")
    }
}

/// Measurement 3: Vision face rectangles on every Nth frame, scaled by the reader.
func runFaces(_ args: Args) async throws {
    let path = try args.requireFile()
    let maxSide = args.int("max", 720)
    let api = args.string("api", "swift")
    let device = args.string("device", "default")
    let revision = args.int("revision", 0)
    let every = args.int("every", 10)
    let limit = args.int("frames", 200)
    let start = args.double("start") ?? 0
    let (asset, track, info) = try await loadVideo(path)
    let (width, height) = scaledSize(info.width, info.height, maxSide: maxSide)
    printFaceDevices()
    log("faces: api=\(api) device=\(device) revision=\(revision == 0 ? "default" : "\(revision)") "
        + "\(width)x\(height) every=\(every) detections=\(limit) start=\(start)s")

    try await runRepeated(args.int("runs", 3)) { _ in
        let detect = try makeFaceDetector(api: api, device: device, revision: revision)
        let (reader, outputs) = try makeReader(asset, track, outputs: [
            ReaderOutput(pixelFormat: kCVPixelFormatType_32BGRA, size: (width, height))
        ], seconds: nil, start: start)
        var index = 0
        var times: [Double] = []
        var faces = 0
        let clock = now()
        while times.count < limit, let sample = outputs[0].copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % every == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = now()
            faces += try await detect(buffer)
            times.append(now() - t)
        }
        reader.cancelReading()
        let wall = now() - clock
        let rest = Array(times.dropFirst())
        var m = Metrics()
        m.set("detections", Double(times.count))
        m.set("first_ms", (times.first ?? 0) * 1000)
        m.set("median_ms", median(rest) * 1000)
        m.set("mean_ms", rest.reduce(0, +) * 1000 / Double(max(1, rest.count)))
        m.set("faces_per_frame", Double(faces) / Double(max(1, times.count)))
        m.set("wall_s", wall)
        return m
    }
}
