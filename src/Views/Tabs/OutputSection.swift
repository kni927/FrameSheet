import SwiftUI

// Output settings (Phase 2): format, JPEG quality, filename template,
// overwrite policy, individual-frame export. Sits after Auto Sampling
// Range in the sidebar column.
struct OutputSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Format")
                    .font(.caption)
                Picker("", selection: Binding(
                    get: { state.outputFormat },
                    set: { state.outputFormat = $0 }
                )) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if state.outputFormat == "jpeg" {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("JPEG Quality")
                        Spacer()
                        Text("\(Int(state.jpegQuality))")
                    }
                    Slider(value: $state.jpegQuality, in: 50...100, step: 1.0)
                }

                if state.backgroundAlpha < 1.0 {
                    Label("JPEG has no transparency — the sheet will be exported over an opaque background.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Filename Template")
                    .font(.caption)
                TextField("", text: Binding(
                    get: { state.filenameTemplate },
                    set: { state.filenameTemplate = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))

                Text("Tokens: {{filename}}, {{width}}, {{height}}, {{columns}}, {{rows}}, {{date}}")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.selectedVideo != nil {
                    Text("→ \(state.resolveFilenameTemplate()).\(state.outputFileExtension)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Toggle("Overwrite existing", isOn: Binding(
                get: { state.overwriteExisting },
                set: { state.overwriteExisting = $0 }
            ))
            .toggleStyle(.checkbox)
            .help("Off: existing files get a _2, _3, … suffix instead of being replaced")

            Toggle("Include individual frames", isOn: Binding(
                get: { state.includeIndividualFrames },
                set: { state.includeIndividualFrames = $0 }
            ))
            .toggleStyle(.checkbox)
            .help("Also save each thumbnail into a <name>_frames/ subfolder when saving")
        }
        .monoFont()
    }
}
