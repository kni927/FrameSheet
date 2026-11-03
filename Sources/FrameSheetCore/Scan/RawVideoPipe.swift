import Darwin
import Foundation

/// Runs ffmpeg writing raw frames to stdout and reads them one at a time
/// (the ffmpeg scan path, §10). Reads block on a private queue, so the
/// calling task only waits; ffmpeg pauses while nobody reads (the pipe
/// fills). Stderr is drained in the background and kept for errors.
/// Terminating (or cancelling the reading task) stops the process.
final class RawVideoPipe: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "FrameSheet.RawVideoPipe")
    private let lock = NSLock()
    private var errorData = Data()
    private let errorsDone = DispatchGroup()

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        try process.run()
        errorsDone.enter()
        let handle = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = handle.readDataToEndOfFile()
            lock.withLock { errorData = data }
            errorsDone.leave()
        }
    }

    private struct Target: @unchecked Sendable {
        var pointer: UnsafeMutableRawPointer
    }

    /// Fills `count` bytes at `buffer` with the next frame; false at the end
    /// of the stream (a trailing partial frame is dropped). Throws
    /// `CancellationError` when the task is cancelled.
    func readFrame(into buffer: UnsafeMutableRawPointer, count: Int) async throws -> Bool {
        let fd = output.fileHandleForReading.fileDescriptor
        let target = Target(pointer: buffer)
        let filled: Int = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    var done = 0
                    while done < count {
                        let n = Darwin.read(fd, target.pointer + done, count - done)
                        if n > 0 {
                            done += n
                        } else if n < 0, errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    continuation.resume(returning: done)
                }
            }
        } onCancel: {
            terminate()
        }
        try Task.checkCancellation()
        return filled == count
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Waits for ffmpeg to exit; returns its status and the error lines.
    /// Closes the read end first: ffmpeg blocked writing to a full pipe
    /// does not act on SIGTERM (the write restarts), but exits on EPIPE.
    func finish() async -> (status: Int32, errors: String) {
        await withCheckedContinuation { continuation in
            // On the read queue, so no read is in progress.
            queue.async { [self] in
                try? output.fileHandleForReading.close()
                process.waitUntilExit()
                errorsDone.wait()
                let text = lock.withLock { String(decoding: errorData, as: UTF8.self) }
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}
