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
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Movies…") { model.presentOpenPanel() }
            }
            // Library undo (§3). Text fields keep their own undo only through
            // the context menu while this replaces the menu items.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
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
                Button(model.showSettings ? "Hide Settings" : "Show Settings") { model.showSettings.toggle() }
                Divider()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
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
    }

    /// Grid keys (§8). Letter, number, arrow and Return keys do nothing while
    /// a text field has focus; ⌘ shortcuts go to the menus.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Only the main window: open panels, the colour panel and alerts
        // keep their own keys.
        guard let model, NSApp.modalWindow == nil, !(event.window is NSPanel) else { return event }
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
        switch event.keyCode {
        case KeyCode.left, KeyCode.right:
            guard flags == [.shift, .option] else { return event }
            model.selectAdjacentThumb(event.keyCode == KeyCode.left ? -1 : 1)
            return nil
        case KeyCode.returnKey, KeyCode.enter:
            guard let thumb = model.selectedThumbId else { return event }
            model.beginScrub(thumb, keyboard: true, modifiers: ScrubModifiers(event.modifierFlags))
            return model.scrub == nil ? event : nil
        default:
            break
        }
        guard flags.subtracting(.shift).isEmpty else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": model.presentOpenPanel()
        case "1": model.showMovieList.toggle()
        case "3": model.showSettings.toggle()
        default: return event
        }
        return nil
    }
}
