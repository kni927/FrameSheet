import SwiftUI

// MARK: - App Entrypoint

@main
struct FrameSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 950, minHeight: 650)
                .preferredColorScheme(.dark)
                .onAppear {
                    AppDelegate.openHandler = { url in
                        appState.handleOpenURL(url)
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    appState.openVideoPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
