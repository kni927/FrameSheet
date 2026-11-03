import AppKit
import FrameSheetCore
import SwiftUI

@main
struct FrameSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some SwiftUI.Scene {
        Window("FrameSheet", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.attach(model) }
                .background(WindowReader { delegate.mainWindow = $0 })
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Movies…") { model.presentOpenPanel() }
            }
            // Library undo (§3), or the typing while a text field is being
            // edited (`AppModel.performUndo`); the toolbar has the same.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canPerformUndo)
                Button("Redo") { model.performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canPerformRedo)
            }
            // View menu; Enter Full Screen (⌃⌘F) comes with the window.
            CommandGroup(before: .toolbar) {
                Button("Fit") { model.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Zoom In") { model.zoom(in: true) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { model.zoom(in: false) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button(model.showMovieList ? "Hide Movie List" : "Show Movie List") { model.showMovieList.toggle() }
                Button(model.showSettings ? "Hide Settings Panel" : "Show Settings Panel") { model.showSettings.toggle() }
                Divider()
                // Key F (the key monitor; a menu shortcut would also fire
                // while a text field has focus).
                Button(model.detectionChart == nil ? "Show Detection Chart" : "Hide Detection Chart") {
                    model.toggleDetectionChart()
                }
                .disabled(model.currentFile == nil)
                Divider()
            }
        }
        Settings {
            SettingsWindow()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    /// Files opened (Open With, the Dock icon) before the window was there.
    private var pendingFiles: [URL] = []
    /// The main window; grid keys act only there, not in Settings.
    weak var mainWindow: NSWindow?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        // Shift, Option and Control change the scrub while dragging.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.model?.optionHeld = event.modifierFlags.contains(.option)
            self?.model?.scrubModifiersChanged(ScrubModifiers(event.modifierFlags))
            return event
        }
    }

    func attach(_ model: AppModel) {
        self.model = model
        if !pendingFiles.isEmpty { model.openFiles(pendingFiles) }
        pendingFiles = []
    }

    /// Open With and drops on the Dock icon: routed like a drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.openFiles(urls) } else { pendingFiles += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveNow()
    }

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let space: UInt16 = 49
    }

    /// Grid keys (§8): A, F, G, M, 1, 2, 3, Space, Escape, the arrows and
    /// Return; in the player view the arrows step and jump, Space switches
    /// a shot sheet's mode, and P plays or pauses.
    /// Letter, number, arrow and Return keys do nothing while a text field
    /// has focus; ⌘ shortcuts go to the menus. The detection chart is a
    /// sheet, another window: its own Esc and F close it.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Only the main window: open panels, the color panel and alerts
        // keep their own keys.
        guard let model, NSApp.modalWindow == nil, !(event.window is NSPanel),
              mainWindow == nil || event.window === mainWindow
        else { return event }
        let flags = event.modifierFlags.intersection([.shift, .option, .control, .command])
        // A keyboard scrub takes the arrows, Return and Escape.
        if let scrub = model.scrub {
            switch event.keyCode {
            case KeyCode.left, KeyCode.right:
                guard scrub.keyboard else { return event }
                let step = flags.contains(.shift) ? 10 : 1
                model.scrubStep(event.keyCode == KeyCode.left ? -step : step)
            case KeyCode.returnKey, KeyCode.enter:
                guard scrub.keyboard else { return event }
                model.endScrub()
            case KeyCode.escape:
                model.cancelScrub()
            default:
                return event
            }
            return nil
        }
        guard !flags.contains(.command), !(event.window?.firstResponder is NSText) else { return event }
        if model.player.isShown, let handled = handlePlayerKey(event, flags: flags, model: model) {
            return handled ? nil : event
        }
        switch event.keyCode {
        case KeyCode.escape:
            // Escape cancels a running shot detection (it resumes later).
            guard model.isScanning, flags.isEmpty else { return event }
            model.cancelScan()
            return nil
        case KeyCode.left, KeyCode.right:
            guard flags == [.shift, .option] else { return event }
            model.selectAdjacentThumb(event.keyCode == KeyCode.left ? -1 : 1)
            return nil
        case KeyCode.returnKey, KeyCode.enter:
            guard let thumb = model.selectedThumbId else { return event }
            model.beginScrub(thumb, keyboard: true, modifiers: ScrubModifiers(event.modifierFlags))
            return model.scrub == nil ? event : nil
        case KeyCode.space:
            // Space opens the player view (§8).
            guard flags.isEmpty, model.currentSheet != nil else { return event }
            model.spacePressed()
            return nil
        default:
            break
        }
        guard flags.subtracting(.shift).isEmpty else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": model.presentOpenPanel()
        case "m": model.saveSheet()
        case "f": model.toggleDetectionChart()
        case "g":
            guard let ref = model.currentRef else { return event }
            model.toggleView(ref)
        case "1": model.showMovieList.toggle()
        case "2":
            guard model.currentSheet != nil || model.player.isShown else { return event }
            model.togglePlayerView()
        case "3": model.showSettings.toggle()
        default: return event
        }
        return nil
    }
}

extension AppDelegate {
    /// Player keys (§8, MoviePrint's `VideoPlayer.handleKeyPress`): ← / →
    /// ±10, with ⇧ ±1, with ⌥ ±100, with ⇧⌥ the previous / next cut (cut
    /// mode) or thumb (thumb mode); Space switches a shot sheet between cut
    /// and thumb mode, elsewhere it closes the player view; P plays and
    /// pauses (§8 names no key for it). Return is reserved for cutting and
    /// changing at the frame, so it does not start a keyboard scrub here.
    /// Returns nil for keys the player does not take.
    fileprivate func handlePlayerKey(_ event: NSEvent, flags: NSEvent.ModifierFlags, model: AppModel) -> Bool? {
        let player = model.player
        switch event.keyCode {
        case KeyCode.left, KeyCode.right:
            let sign = event.keyCode == KeyCode.left ? -1 : 1
            if flags == [.shift, .option] {
                player.jump(sign < 0 ? .previous : .next)
            } else if flags.subtracting([.shift, .option]).isEmpty {
                let step = PlayerNavigation.arrowStep(shift: flags.contains(.shift), option: flags.contains(.option))
                player.step(sign * step)
            } else {
                return false
            }
            return true
        case KeyCode.space:
            guard flags.isEmpty else { return false }
            model.spacePressed()
            return true
        case KeyCode.returnKey, KeyCode.enter:
            return true
        default:
            break
        }
        guard flags.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "p" else { return nil }
        player.togglePlayback()
        return true
    }
}

/// Hands its window to `onWindow` once it is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
