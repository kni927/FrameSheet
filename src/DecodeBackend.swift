import Foundation

// Abstraction over frame-decoding engines. AppState talks only to this
// protocol; concrete backends are FFmpegBackend (process-spawn, any
// format ffmpeg supports) and AVFoundationBackend (in-process hardware
// decode for natively supported containers).
protocol DecodeBackend: AnyObject {
    var name: String { get }

    // Human-readable diagnostics appended to the app console. Backends
    // must invoke this on the main queue.
    var logSink: ((String) -> Void)? { get set }

    // Probe/open the file synchronously (fast metadata read; called on
    // main). A failure means this backend cannot produce frames for the
    // file — during routing that triggers fallback, not necessarily a
    // user-facing error.
    func open(url: URL) -> Result<VideoFileInfo, DecodeBackendError>

    // Estimate duration for files whose metadata lacks it.
    // completion(duration, wasCancelled) runs on main.
    func estimateDuration(url: URL, completion: @escaping (Double?, Bool) -> Void)

    // Extract one frame per timestamp, scaled to scaleWidth (preserving
    // aspect), written as thumb_%04d.jpg into tempDir in timestamp-array
    // order. completion(extractedCount, wasCancelled, actualTimestamps)
    // runs on main; actualTimestamps maps a timestamp-array index to the
    // frame time actually decoded when it differs from the request (e.g.
    // the AVFoundation bounded-tolerance retry — see Decisions).
    func extractFrames(url: URL, timestamps: [Double], scaleWidth: Int, tempDir: String,
                       completion: @escaping (Int, Bool, [Int: Double]) -> Void)

    // Extract a single frame (per-cell nudge path).
    // completion(success, errorText, actualTimestamp) runs on main;
    // actualTimestamp is non-nil when the decoded frame's time differs
    // from the request.
    func extractSingleFrame(url: URL, timestamp: Double, scaleWidth: Int, outPath: String,
                            completion: @escaping (Bool, String?, Double?) -> Void)

    // Terminate all in-flight work. Returns true if anything was
    // actually cancelled.
    @discardableResult func cancelAll() -> Bool

    // Release resources held for the current file.
    func close()
}

struct DecodeBackendError: Error {
    let message: String
}
