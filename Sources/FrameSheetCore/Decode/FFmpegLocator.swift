import Foundation

/// A working ffmpeg (and the ffprobe next to it) with its version.
public struct FFmpegTools: Sendable, Equatable {
    public enum Source: String, Sendable {
        case user = "chosen path"
        case loginShell = "login shell"
        case knownLocation = "known location"
    }

    public var ffmpeg: URL
    /// nil when no ffprobe sits next to ffmpeg; the ffmpeg path then
    /// cannot probe files.
    public var ffprobe: URL?
    /// The version from `ffmpeg -version`, e.g. "8.0".
    public var version: String
    public var source: Source
}

public struct FFmpegDiscovery: Sendable {
    public var tools: FFmpegTools?
    /// Why earlier candidates were skipped, e.g. an invalid chosen path.
    public var notes: [String]
}

/// Finds ffmpeg in the order of docs/V3_SPEC.md §10: the user's chosen path,
/// then `command -v ffmpeg` in a login shell, then the known install
/// directories. Every candidate must answer `ffmpeg -version`.
public struct FFmpegLocator: Sendable {
    public var userPath: String?
    public var loginShellLookup: @Sendable () async -> String?
    public var knownDirectories: [String]

    public static var defaultKnownDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
        ]
    }

    public init(
        userPath: String?,
        loginShellLookup: @escaping @Sendable () async -> String? = FFmpegLocator.loginShellFFmpeg,
        knownDirectories: [String] = FFmpegLocator.defaultKnownDirectories
    ) {
        self.userPath = userPath
        self.loginShellLookup = loginShellLookup
        self.knownDirectories = knownDirectories
    }

    public func discover() async -> FFmpegDiscovery {
        var notes: [String] = []

        if let userPath, !userPath.isEmpty {
            var url = URL(fileURLWithPath: (userPath as NSString).expandingTildeInPath)
            if url.hasDirectoryPath || isDirectory(url) { url.append(path: "ffmpeg") }
            if let tools = await Self.validate(url, source: .user) {
                return FFmpegDiscovery(tools: tools, notes: notes)
            }
            notes.append("The chosen path \(userPath) is not a working ffmpeg; searching instead.")
        }

        if let path = await loginShellLookup(),
           let tools = await Self.validate(URL(fileURLWithPath: path), source: .loginShell) {
            return FFmpegDiscovery(tools: tools, notes: notes)
        }

        for directory in knownDirectories {
            let url = URL(fileURLWithPath: directory).appending(path: "ffmpeg")
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if let tools = await Self.validate(url, source: .knownLocation) {
                return FFmpegDiscovery(tools: tools, notes: notes)
            }
        }
        notes.append("ffmpeg was not found. Install it, for example with `brew install ffmpeg`.")
        return FFmpegDiscovery(tools: nil, notes: notes)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Runs `ffmpeg -version`; nil unless it exits 0 and names a version.
    public static func validate(_ url: URL, source: FFmpegTools.Source) async -> FFmpegTools? {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let result = try? await ProcessRunner.run(url, ["-version"], timeout: .seconds(10)),
              result.status == 0, !result.timedOut,
              let version = parseVersion(result.stdoutText)
        else { return nil }
        let probe = url.deletingLastPathComponent().appending(path: "ffprobe")
        return FFmpegTools(
            ffmpeg: url,
            ffprobe: FileManager.default.isExecutableFile(atPath: probe.path) ? probe : nil,
            version: version, source: source)
    }

    /// "ffmpeg version 8.0 Copyright …" → "8.0".
    static func parseVersion(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").first, line.hasPrefix("ffmpeg version ") else {
            return nil
        }
        return line.dropFirst("ffmpeg version ".count).split(separator: " ").first.map(String.init)
    }

    /// `command -v ffmpeg` in an interactive login zsh, so PATH set in
    /// .zprofile or .zshrc counts. Takes the last absolute path printed, as
    /// shell start-up files may print other lines.
    @Sendable public static func loginShellFFmpeg() async -> String? {
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/zsh"), ["-lic", "command -v ffmpeg"], timeout: .seconds(10)),
            result.status == 0
        else { return nil }
        return result.stdoutText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }
}
