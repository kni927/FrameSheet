import AppKit

// MARK: - App Delegate (Finder / Dock file opens)

class AppDelegate: NSObject, NSApplicationDelegate {
    // Routes Finder/Dock file-open events into AppState.loadVideo(url:).
    // Set once the SwiftUI hierarchy is up; a URL arriving earlier (e.g.
    // app launched by double-clicking a movie) is stashed and delivered
    // as soon as the handler is assigned.
    static var openHandler: ((URL) -> Void)? {
        didSet {
            if let handler = openHandler, let url = pendingURL {
                pendingURL = nil
                handler(url)
            }
        }
    }
    private static var pendingURL: URL? = nil

    func application(_ application: NSApplication, open urls: [URL]) {
        // Single-file policy: the app holds at most one video at a time.
        guard let url = urls.first else { return }
        if let handler = AppDelegate.openHandler {
            handler(url)
        } else {
            AppDelegate.pendingURL = url
        }
    }
}
