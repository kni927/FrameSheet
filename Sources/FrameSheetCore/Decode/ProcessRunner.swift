import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a command without a shell (arguments are passed as they are, so
/// paths need no quoting) and collects stdout and stderr. Both pipes are
/// drained while the process runs, so large output cannot block it. The
/// process is terminated when the calling task is cancelled or the
/// timeout passes, and killed when it still runs `killGrace` later (one that
/// ignores SIGTERM would otherwise hold its caller, and the DecodeGate a
/// caller holds, for as long as it runs).
public enum ProcessRunner {
    /// How long a terminated process may take to exit before it is killed.
    static let killGrace: Double = 2
    /// How long the pipes may stay open after the process exited (a child
    /// it started can keep them open); then what arrived is the output.
    static let drainGrace: Double = 2

    public static func run(
        _ executable: URL, _ arguments: [String], timeout: Duration? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let job = Job(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try job.run(timeout: timeout) })
                }
            }
        } onCancel: {
            job.terminate()
        }
    }

    /// Owns the Process; its state is only touched under `lock`.
    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var started = false
        private var cancelled = false
        private var timedOut = false
        /// Left when the process has exited. Awaited instead of
        /// `waitUntilExit`, which is not always woken when the process
        /// exits after it started waiting (see `RawVideoPipe.finish`).
        private let exited = DispatchGroup()

        init(executable: URL, arguments: [String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [exited] _ in exited.leave() }
        }

        func run(timeout: Duration?) throws -> ProcessResult {
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            lock.lock()
            if cancelled {
                lock.unlock()
                throw CancellationError()
            }
            exited.enter()
            do {
                try process.run()
            } catch {
                exited.leave()
                lock.unlock()
                throw error
            }
            started = true
            lock.unlock()

            if let timeout {
                let seconds = Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                    lock.lock()
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                        killLater()
                    }
                    lock.unlock()
                }
            }

            // Both pipes drain in the background while the process runs; the
            // wait for them after its exit is bounded, since a child it left
            // running may hold them open for as long as it lives.
            let outputData = LockedData()
            let errorData = LockedData()
            let drained = DispatchGroup()
            for (pipe, sink) in [(out, outputData), (err, errorData)] {
                drained.enter()
                let handle = pipe.fileHandleForReading
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        sink.append(chunk)
                    }
                    drained.leave()
                }
            }
            exited.wait()
            _ = drained.wait(timeout: .now() + ProcessRunner.drainGrace)

            lock.lock()
            let wasCancelled = cancelled
            let wasTimedOut = timedOut
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            return ProcessResult(
                status: process.terminationStatus, stdout: outputData.get(), stderr: errorData.get(),
                timedOut: wasTimedOut)
        }

        func terminate() {
            lock.lock()
            cancelled = true
            if started && process.isRunning {
                process.terminate()
                killLater()
            }
            lock.unlock()
        }

        /// SIGKILL after `killGrace` if the process still runs; on its own
        /// queue, not behind the blocked pipe reads. Called under `lock`.
        private func killLater() {
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGrace) { [self] in
                lock.lock()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ value: Data) { lock.withLock { data.append(value) } }
        func get() -> Data { lock.withLock { data } }
    }
}

extension URL {
    /// The file path in Unicode NFC, as passed to ffmpeg and ffprobe (v2
    /// did the same for file names with decomposed accents).
    public var nfcPath: String {
        path(percentEncoded: false).precomposedStringWithCanonicalMapping
    }
}
