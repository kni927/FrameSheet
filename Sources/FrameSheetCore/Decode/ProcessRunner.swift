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
/// timeout passes.
public enum ProcessRunner {
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

        init(executable: URL, arguments: [String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
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
            do {
                try process.run()
            } catch {
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
                    }
                    lock.unlock()
                }
            }

            let errorData = LockedData()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errorData.set(err.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            let outputData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()

            lock.lock()
            let wasCancelled = cancelled
            let wasTimedOut = timedOut
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            return ProcessResult(
                status: process.terminationStatus, stdout: outputData, stderr: errorData.get(),
                timedOut: wasTimedOut)
        }

        func terminate() {
            lock.lock()
            cancelled = true
            if started && process.isRunning { process.terminate() }
            lock.unlock()
        }
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
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
