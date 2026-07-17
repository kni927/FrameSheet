import SwiftUI

// MARK: - Views

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            TopBarView()

            // Middle Content Split View
            HSplitView {
                // Sidebar controls — widened from 180 to fit the flattened
                // single-scroll-column settings layout (Phase 1, Stage B)
                SidebarView()
                    .frame(width: 240)
                    .frame(minWidth: 200, maxWidth: 280)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.85))

                // Canvas preview
                CanvasView()
                    .frame(minWidth: 500)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.11))
            }

            // Collapsible Console
            if state.showConsole {
                ConsoleView()
                    .frame(height: 180)
                    .transition(.move(edge: .bottom))
            }
        }
        .monoFont() // Set SF Mono globally
        .alert(item: Binding<AlertError?>(
            get: { state.errorMessage.map { AlertError(message: $0) } },
            set: { _ in state.errorMessage = nil }
        )) { err in
            Alert(
                title: Text("Error"),
                message: Text(err.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct AlertError: Identifiable {
    let id = UUID()
    let message: String
}
