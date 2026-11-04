import Darwin
import Foundation

/// Runs ffmpeg writing raw frames to stdout and reads them one at a time
/// (the ffmpeg scan path, §10). Reads block on a private queue, so the
/// calling task only waits; ffmpeg pauses while nobody reads (the pipe
/// fills). Stderr is drained in the background and kept for errors.
/// Terminating (or cancelling the reading task) stops the process. With
/// `onErrorLine`, each stderr line is also handed over as it arrives (the
/// player's ffmpeg playback reads `showinfo` timestamps while it plays).
final class RawVideoPipe: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "FrameSheet.RawVideoPipe")
    private let lock = NSLock()
    private var errorData = Data()
    private let errorsDone = DispatchGroup()
    /// Left when the process has exited (its termination handler).
    private let exited = DispatchGroup()
    private let onErrorLine: (@Sendable (Substring) -> Void)?

    /// How long `finish` waits after closing the pipe before killing ffmpeg.
    static let exitGrace: DispatchTimeInterval = .seconds(5)

    init(executable: URL, arguments: [String], onErrorLine: (@Sendable (Substring) -> Void)? = nil) {
        self.onErrorLine = onErrorLine
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [exited] _ in exited.leave() }
    }

    func start() throws {
        exited.enter()
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }
        errorsDone.enter()
        let handle = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let onErrorLine else {
                let data = handle.readDataToEndOfFile()
                lock.withLock { errorData = data }
                errorsDone.leave()
                return
            }
            // Line by line as it arrives; the whole text is kept as well.
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.withLock { errorData.append(chunk) }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    onErrorLine(Substring(line))
                }
            }
            if !pending.isEmpty { onErrorLine(Substring(String(decoding: pending, as: UTF8.self))) }
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
    /// does not act on SIGTERM (the write restarts), but exits on EPIPE;
    /// one that still runs after `exitGrace` is killed.
    ///
    /// The exit is awaited through the termination handler, not
    /// `waitUntilExit`: that sleeps in this thread's run loop and, when the
    /// process exits after it started waiting (as after a cancel), was not
    /// always woken, which left the scan holding the DecodeGate for good
    /// (the hang in `cancelledScanResumes`, 2026-11-03).
    func finish() async -> (status: Int32, errors: String) {
        await withCheckedContinuation { continuation in
            // On the read queue, so no read is in progress.
            queue.async { [self] in
                try? output.fileHandleForReading.close()
                if exited.wait(timeout: .now() + Self.exitGrace) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
                errorsDone.wait()
                let text = lock.withLock { String(decoding: errorData, as: UTF8.self) }
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}
