import Foundation

// The original process-spawn decode path, wrapped behind DecodeBackend.
// Handles any container/codec the system ffmpeg supports; since the
// AVFoundation backend became primary this is the fallback for formats
// AVFoundation cannot open (WebM/MKV, etc.). Invocation conventions are
// unchanged from the pre-abstraction code: one input-seeking invocation
// per frame (`-ss <t> -i <file> -frames:v 1`), 5-way concurrent, JPEG
// `-q:v 3` temporaries, and a two-attempt packet-timestamp scan for
// duration-less files.
final class FFmpegBackend: DecodeBackend {
    let name = "ffmpeg"
    var logSink: ((String) -> Void)? = nil

    private let ffmpegPath: String
    private let ffprobePath: String

    // In-flight process bookkeeping (guarded by processLock)
    private let processLock = NSLock()
    private var parallelProcesses: [Process] = []
    private var parallelCancelled = false
    private var estimationProcess: Process? = nil
    private var estimationCancelled = false

    init(ffmpegPath: String, ffprobePath: String) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { self.logSink?(message) }
    }

    // MARK: - Probe

    func open(url: URL) -> Result<VideoFileInfo, DecodeBackendError> {
        let probeCmd = "\"\(ffprobePath.isEmpty ? "ffprobe" : ffprobePath)\" -v error -show_format -show_streams -print_format json \"\(url.path)\""
        let result = runShellSync(probeCmd)
        if result.status != 0 {
            return .failure(DecodeBackendError(message: "Failed to analyze video: \(result.stderr)"))
        }
        guard let data = result.stdout.data(using: .utf8) else {
            return .failure(DecodeBackendError(message: "Failed to decode ffprobe output."))
        }
        do {
            let decoded = try JSONDecoder().decode(FFProbeResult.self, from: data)
            var videoInfo = VideoFileInfo(url: url)
            if let durationStr = decoded.format?.duration, let dur = Double(durationStr) {
                videoInfo.duration = dur
            }
            if let sizeStr = decoded.format?.size, let sz = Int64(sizeStr) {
                videoInfo.size = sz
            }
            if let streams = decoded.streams,
               let videoStream = streams.first(where: { $0.codec_type == "video" }) {
                videoInfo.width = videoStream.width ?? 0
                videoInfo.height = videoStream.height ?? 0
                videoInfo.codec = videoStream.codec_name ?? "Unknown"
                videoInfo.frameRate = videoStream.r_frame_rate ?? ""
                if videoInfo.duration == 0, let streamDurStr = videoStream.duration,
                   let dur = Double(streamDurStr) {
                    videoInfo.duration = dur
                }
            }
            videoInfo.isLoaded = true
            return .success(videoInfo)
        } catch {
            return .failure(DecodeBackendError(message: "Failed to parse metadata JSON: \(error.localizedDescription)"))
        }
    }

    // MARK: - Duration estimation (packet scan)

    // Attempt 1 seeks to an unreachably late timestamp and reads the
    // trailing packets — instant for indexed containers; for a cues-less
    // WebM the demuxer falls back to a linear scan, which is still
    // IO-bound only. Attempt 2 is an explicit full scan taking the max
    // pts_time. Cancellable via cancelAll().
    func estimateDuration(url: URL, completion: @escaping (Double?, Bool) -> Void) {
        log(">>> Duration missing from metadata; estimating via packet scan...\n")
        processLock.lock()
        estimationCancelled = false
        processLock.unlock()

        let probe = ffprobePath.isEmpty ? "ffprobe" : ffprobePath
        let nfcPath = url.path.precomposedStringWithCanonicalMapping
        let baseArgs = ["-v", "error", "-select_streams", "v:0",
                        "-show_entries", "packet=pts_time", "-of", "csv=p=0"]

        DispatchQueue.global(qos: .userInitiated).async {
            var result = self.maxPTS(fromProbe: probe, args: baseArgs + ["-read_intervals", "9999999", nfcPath])
            if result == nil && !self.isEstimationCancelled() {
                result = self.maxPTS(fromProbe: probe, args: baseArgs + [nfcPath])
            }
            let wasCancelled = self.isEstimationCancelled()
            DispatchQueue.main.async {
                completion(result, wasCancelled)
            }
        }
    }

    private func isEstimationCancelled() -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return estimationCancelled
    }

    // Run one ffprobe packet listing and return the maximum pts_time,
    // or nil on failure/cancellation/empty output. Blocking; call off-main.
    private func maxPTS(fromProbe probe: String, args: [String]) -> Double? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: probe)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice

        processLock.lock()
        if estimationCancelled {
            processLock.unlock()
            return nil
        }
        estimationProcess = task
        processLock.unlock()

        defer {
            processLock.lock()
            if estimationProcess === task { estimationProcess = nil }
            processLock.unlock()
        }

        do {
            try task.run()
        } catch {
            return nil
        }
        // Read before waiting so a large packet list can't fill the pipe
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        let maxSeen = text.split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .max()
        guard let m = maxSeen, m > 0, m.isFinite else { return nil }
        return m
    }

    // MARK: - Batch extraction

    // One input-seeking ffmpeg invocation per frame (-ss before -i only
    // decodes from the nearest keyframe, frame-accurate in modern
    // ffmpeg), run 5-concurrent. Software decode: a single GOP per
    // invocation is cheap, and videotoolbox init overhead would dominate.
    func extractFrames(url: URL, timestamps: [Double], scaleWidth: Int, tempDir: String,
                       completion: @escaping (Int, Bool) -> Void) {
        let ff = ffmpegPath
        let videoPath = url.path.precomposedStringWithCanonicalMapping
        processLock.lock()
        parallelCancelled = false
        parallelProcesses.removeAll()
        processLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let semaphore = DispatchSemaphore(value: 5)
            let group = DispatchGroup()
            let countLock = NSLock()
            var extracted = 0

            for (i, t) in timestamps.enumerated() {
                semaphore.wait()
                self.processLock.lock()
                let cancelled = self.parallelCancelled
                self.processLock.unlock()
                if cancelled {
                    semaphore.signal()
                    break
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    let outPath = String(format: "%@/thumb_%04d.jpg", tempDir, i + 1)
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: ff)
                    task.arguments = [
                        "-hide_banner", "-loglevel", "error",
                        "-ss", String(format: "%.3f", t),
                        "-i", videoPath,
                        "-frames:v", "1",
                        "-vf", "scale=\(scaleWidth):-2",
                        "-q:v", "3",
                        "-y", outPath
                    ]
                    task.standardOutput = FileHandle.nullDevice
                    let errPipe = Pipe()
                    task.standardError = errPipe

                    self.processLock.lock()
                    if self.parallelCancelled {
                        self.processLock.unlock()
                        return
                    }
                    self.parallelProcesses.append(task)
                    self.processLock.unlock()

                    var launched = false
                    do {
                        try task.run()
                        launched = true
                        task.waitUntilExit()
                    } catch {
                        self.log("Frame \(i + 1): failed to launch ffmpeg: \(error.localizedDescription)\n")
                    }

                    self.processLock.lock()
                    if let idx = self.parallelProcesses.firstIndex(where: { $0 === task }) {
                        self.parallelProcesses.remove(at: idx)
                    }
                    self.processLock.unlock()

                    // Drain stderr even on success so the pipe can't fill up
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if launched && task.terminationStatus == 0
                        && FileManager.default.fileExists(atPath: outPath) {
                        countLock.lock()
                        extracted += 1
                        countLock.unlock()
                    } else if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
                        self.log("Frame \(i + 1) (t=\(String(format: "%.1f", t))s): \(err)")
                    }
                }
            }

            group.wait()
            self.processLock.lock()
            let wasCancelled = self.parallelCancelled
            self.processLock.unlock()
            countLock.lock()
            let total = extracted
            countLock.unlock()
            DispatchQueue.main.async {
                completion(total, wasCancelled)
            }
        }
    }

    // MARK: - Single-frame extraction (nudge)

    func extractSingleFrame(url: URL, timestamp: Double, scaleWidth: Int, outPath: String,
                            completion: @escaping (Bool, String?) -> Void) {
        let ff = ffmpegPath
        let videoPath = url.path.precomposedStringWithCanonicalMapping
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ff)
            task.arguments = [
                "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.3f", timestamp),
                "-i", videoPath,
                "-frames:v", "1",
                "-vf", "scale=\(scaleWidth):-2",
                "-q:v", "3",
                "-y", outPath
            ]
            task.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            task.standardError = errPipe
            var launched = false
            do {
                try task.run()
                launched = true
                task.waitUntilExit()
            } catch {}
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let ok = launched && task.terminationStatus == 0
                && FileManager.default.fileExists(atPath: outPath)
            let errText = String(data: errData, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            DispatchQueue.main.async {
                completion(ok, errText)
            }
        }
    }

    // MARK: - Cancellation / teardown

    @discardableResult
    func cancelAll() -> Bool {
        processLock.lock()
        parallelCancelled = true
        estimationCancelled = true
        let procs = parallelProcesses
        let estimation = estimationProcess
        processLock.unlock()

        var didCancel = false
        for p in procs where p.isRunning {
            p.terminate()
            didCancel = true
        }
        if let est = estimation, est.isRunning {
            est.terminate()
            didCancel = true
        }
        return didCancel
    }

    func close() {
        cancelAll()
    }

    // MARK: - Helpers

    private func runShellSync(_ command: String) -> (stdout: String, stderr: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/Users/kni/miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + currentPath
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
