import Foundation

/// Paths as the owner reads them: under the home directory as `~/…`
/// (header folder line, Output folder, movie list). Tooltips keep the full
/// path.
public enum PathDisplay {
    /// `path` with a leading `home` replaced by `~`; other paths unchanged.
    /// Only whole components match: with home `/home/a`, `/home/ab` stays.
    public static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
