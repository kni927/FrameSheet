import AppKit
import SwiftUI

@main
struct FrameSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("FrameSheet", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Movies…") { model.presentOpenPanel() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveNow()
    }

    /// Single-key shortcuts (§8). They do nothing while a text field has
    /// focus or a modifier other than Shift is held.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let model,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(event.window?.firstResponder is NSText)
        else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": model.presentOpenPanel()
        case "1": model.showMovieList.toggle()
        case "3": model.showSettings.toggle()
        default: return event
        }
        return nil
    }
}
