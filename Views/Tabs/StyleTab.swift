import SwiftUI
import AppKit

struct StyleTab: View {
    @EnvironmentObject var state: AppState

    // Preset Colors
    let bgPresets: [Color] = [.black, Color(red: 0.1, green: 0.1, blue: 0.1), Color(red: 0.8, green: 0.8, blue: 0.8), .white]
    let fgPresets: [Color] = [.white, Color(red: 0.7, green: 0.7, blue: 0.7), .yellow, .black]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Font settings
            Text("Font Settings")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Font Family")
                    .font(.caption)
                Picker("", selection: Binding(
                    get: { state.selectedFont },
                    set: {
                        state.selectedFont = $0
                        state.autoGenerateIfNeeded()
                    }
                )) {
                    Text("Hiragino Sans (Default)").tag("Hiragino Sans")
                    Text("Helvetica").tag("Helvetica")
                    Text("Times New Roman").tag("Times")
                    Text("Custom...").tag("Custom")
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if state.selectedFont == "Custom" {
                    HStack(spacing: 8) {
                        Text(state.customFontPath.isEmpty ? "No font selected" : URL(fileURLWithPath: state.customFontPath).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.gray)
                            .font(.system(size: 10, design: .monospaced))

                        Button("Browse") {
                            selectCustomFontFile()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.bottom, 6)

            Divider()

            // Color presets
            Text("Colors")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            ColorPresetSelector(title: "Background Color", selectedColor: Binding(
                get: { state.backgroundColor },
                set: {
                    state.backgroundColor = $0
                    state.autoGenerateIfNeeded()
                }
            ), presets: bgPresets)

            ColorPresetSelector(title: "Text/Font Color", selectedColor: Binding(
                get: { state.textColor },
                set: {
                    state.textColor = $0
                    state.autoGenerateIfNeeded()
                }
            ), presets: fgPresets)

            Divider()

            // Layout & Options
            Text("Visual Elements")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            Toggle("Show Movie Info Header", isOn: Binding(
                get: { state.showHeader },
                set: {
                    state.showHeader = $0
                    state.autoGenerateIfNeeded()
                }
            ))
            .toggleStyle(.checkbox)

            if state.showHeader {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Customize Header Text", isOn: Binding(
                        get: { state.useCustomHeaderTemplate },
                        set: {
                            state.useCustomHeaderTemplate = $0
                            state.autoGenerateIfNeeded()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    if state.useCustomHeaderTemplate {
                        TextEditor(text: Binding(
                            get: { state.customHeaderTemplate },
                            set: {
                                state.customHeaderTemplate = $0
                            }
                        ))
                        .font(.system(size: 9, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.gray.opacity(0.3))
                        .cornerRadius(4)

                        Text("Placeholders: {{filename}}, {{size}}, {{duration}}, {{sample_width}}x{{sample_height}}, {{video_codec}}, {{frame_rate}}")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 4)
            }

            Toggle("Show Timestamp overlays", isOn: Binding(
                get: { state.showTimestamps },
                set: {
                    state.showTimestamps = $0
                    state.autoGenerateIfNeeded()
                }
            ))
            .toggleStyle(.checkbox)

            if state.showTimestamps {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timestamp Position")
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { state.timestampPosition },
                            set: {
                                state.timestampPosition = $0
                                state.autoGenerateIfNeeded()
                            }
                        )) {
                            Text("Top-Left").tag("top-left")
                            Text("Top-Right").tag("top-right")
                            Text("Bottom-Left").tag("bottom-left")
                            Text("Bottom-Right").tag("bottom-right")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(.bottom, 4)

                    Toggle("Customize Timestamps", isOn: Binding(
                        get: { state.useCustomTimestamps },
                        set: {
                            state.useCustomTimestamps = $0
                            state.autoGenerateIfNeeded()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    if state.useCustomTimestamps {
                        TextEditor(text: Binding(
                            get: { state.customTimestampsText },
                            set: {
                                state.customTimestampsText = $0
                            }
                        ))
                        .font(.system(size: 9, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.gray.opacity(0.3))
                        .cornerRadius(4)

                        Text("Enter comma-separated timestamps (format: h:mm:ss.mmmm or mm:ss)\nExample: 0:01:15, 0:03:45.500")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 4)
            }
        }
        .monoFont()
    }

    private func selectCustomFontFile() {
        FontPanelBridge.shared.showFontPanel(currentFontName: state.selectedFont) { fontName in
            if let font = NSFont(name: fontName, size: 12.0) {
                let ctFont = font as CTFont
                if let url = CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL {
                    DispatchQueue.main.async {
                        state.selectedFont = "Custom"
                        state.customFontPath = url.path
                        state.autoGenerateIfNeeded()
                    }
                }
            }
        }
    }
}
