import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Console Log Monitor

struct ConsoleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Console Header
            HStack {
                Label("Console Log Monitor", systemImage: "terminal.fill")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Button("Copy All") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(state.consoleOutput, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

                Divider()
                    .frame(height: 12)

                Button("Export Log") {
                    exportLogToFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

                Divider()
                    .frame(height: 12)

                Button("Clear Logs") {
                    state.consoleOutput = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

                Divider()
                    .frame(height: 12)

                Button(action: { withAnimation { state.showConsole = false } }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Output text area
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.consoleOutput.isEmpty ? "No log output yet." : state.consoleOutput)
                        .textSelection(.enabled) // Enable drag-selection and copy
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(state.consoleOutput.isEmpty ? .gray : Color(NSColor.textColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("bottom_anchor")
                }
                .background(Color(NSColor.controlBackgroundColor))
                .onChange(of: state.consoleOutput) {
                    // Automatically scroll to bottom on logs
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
        }
    }

    private func exportLogToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "framesheet_console_log.txt"

        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                do {
                    try state.consoleOutput.write(to: targetURL, atomically: true, encoding: .utf8)
                } catch {
                    state.errorMessage = "Failed to export log: \(error.localizedDescription)"
                }
            }
        }
    }
}
