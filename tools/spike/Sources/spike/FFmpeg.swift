import Foundation

/// Runs a tool found on PATH and returns its stdout as text.
private func capture(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Measurement 6: system ffmpeg decoding to a BGRA rawvideo pipe.
func runFFmpeg(_ args: Args) async throws {
    let path = try args.requireFile()
    let maxSide = args.int("max", 240)
    let hwaccel = args.flag("hwaccel")
    let seconds = args.double("seconds")
    let probe = try capture(["ffprobe", "-v", "error", "-select_streams", "v:0",
                             "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", path])
    let fields = probe.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
    guard fields.count >= 3, let sourceWidth = Int(fields[1]), let sourceHeight = Int(fields[2]) else {
        throw SpikeError("ffprobe gave no video size: \(probe)")
    }
    let (width, height) = scaledSize(sourceWidth, sourceHeight, maxSide: maxSide)
    log("input: \(fields[0]) \(sourceWidth)x\(sourceHeight)")
    log("ffmpeg: bgra \(width)x\(height) hwaccel=\(hwaccel) range=\(seconds.map { "\($0)s" } ?? "whole file")")

    try await runRepeated(args.int("runs", 3)) { _ in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-v", "error", "-nostdin"]
            + (hwaccel ? ["-hwaccel", "videotoolbox"] : [])
            + (seconds.map { ["-t", "\($0)"] } ?? [])
            + ["-i", path, "-an", "-sn", "-vf", "scale=\(width):\(height)",
               "-pix_fmt", "bgra", "-f", "rawvideo", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        let cpuStart = cpuSeconds(children: true)
        let systemStart = systemTicks()
        let start = now()
        try process.run()
        var bytes = 0
        let handle = pipe.fileHandleForReading
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            bytes += chunk.count
        }
        process.waitUntilExit()
        let wall = now() - start
        guard process.terminationStatus == 0 else {
            throw SpikeError("ffmpeg exited with \(process.terminationStatus)")
        }
        let frames = bytes / (width * height * 4)
        var m = Metrics()
        m.set("frames", Double(frames))
        m.set("wall_s", wall)
        m.set("fps", Double(frames) / wall)
        m.set("cpu_cores", (cpuSeconds(children: true) - cpuStart) / wall)
        m.set("system_cores", systemCores(since: systemStart))
        return m
    }
}
