import Foundation

extension AppState {
    // Check system commands and Python packages
    func checkDependencies() {
        self.isCheckingDependencies = true
        self.dependencyCheckMessage = "Checking environment..."

        DispatchQueue.global(qos: .userInitiated).async {
            let ff = self.findCommandPath("ffmpeg")
            let probe = self.findCommandPath("ffprobe")
            let ok = !ff.isEmpty && !probe.isEmpty

            DispatchQueue.main.async {
                self.ffmpegPath = ff
                self.ffprobePath = probe
                self.isFFmpegInstalled = ok
                self.isCheckingDependencies = false

                if ff.isEmpty || probe.isEmpty {
                    self.dependencyCheckMessage = "FFmpeg/FFprobe not found. Install via Homebrew: 'brew install ffmpeg'."
                } else {
                    self.dependencyCheckMessage = "FFmpeg \(ff) — Ready!"
                }

                // A Finder/Dock open may have arrived while the check was
                // still running (cold start); process it now that the
                // ffmpeg/ffprobe paths are settled. Flushed even if the
                // check failed so the user still gets a clear error.
                if let url = self.pendingOpenURL {
                    self.pendingOpenURL = nil
                    self.loadVideo(url: url)
                }
            }
        }
    }

    // Entry point for Finder/Dock open events. Defers the load while the
    // async ffmpeg dependency check is still running, so the initial
    // auto-generation doesn't race a not-yet-set ffmpeg path.
    func handleOpenURL(_ url: URL) {
        if isCheckingDependencies {
            pendingOpenURL = url
        } else {
            loadVideo(url: url)
        }
    }

    func findCommandPath(_ cmd: String) -> String {
        // Search in common PATHs first to override shell environment limits
        let searchPaths = [
            "/Users/kni/miniforge3/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        for dir in searchPaths {
            let fullPath = (dir as NSString).appendingPathComponent(cmd)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        // Fallback to "which"
        let res = executeShellSync("which \(cmd)")
        if res.status == 0 {
            return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }

    // Direct synchronous command execution for checkups
    func executeShellSync(_ command: String) -> (stdout: String, stderr: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]

        // Provide rich PATH variables
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

            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            return (outStr, errStr, task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
