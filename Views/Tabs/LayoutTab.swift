import SwiftUI

// MARK: - Tab Panels

struct LayoutTab: View {
    @EnvironmentObject var state: AppState

    static let widthPresets = [1200, 1600, 2048, 3200]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grid Dimensions")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            VStack(spacing: 8) {
                HStack {
                    Text("Columns")
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: {
                            if state.columns > 1 {
                                state.columns -= 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("\(state.columns)")
                            .frame(width: 22, alignment: .center)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))

                        Button(action: {
                            if state.columns < 50 {
                                state.columns += 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Text("Rows")
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: {
                            if state.rows > 1 {
                                state.rows -= 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("\(state.rows)")
                            .frame(width: 22, alignment: .center)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))

                        Button(action: {
                            if state.rows < 50 {
                                state.rows += 1
                                state.autoGenerateIfNeeded()
                            }
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            Text("Size & Spacing")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size Preset")
                        .font(.caption)
                    Picker("", selection: Binding(
                        get: {
                            LayoutTab.widthPresets.contains(state.imageWidth) ? "\(state.imageWidth)" : "custom"
                        },
                        set: { newValue in
                            if let w = Int(newValue) {
                                state.imageWidth = w
                                state.autoGenerateIfNeeded()
                            }
                            // "custom" is display-only: it appears when the
                            // width slider leaves the preset values
                        }
                    )) {
                        ForEach(LayoutTab.widthPresets, id: \.self) { w in
                            Text("\(w) px").tag("\(w)")
                        }
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                HStack {
                    Text("Image Width")
                    Spacer()
                    Text("\(state.imageWidth) px")
                }
                Slider(value: Binding(
                    get: { Double(state.imageWidth) },
                    set: { state.imageWidth = Int($0) }
                ), in: 600...3200, step: 50.0)

                if state.selectedVideo != nil {
                    HStack {
                        Text("Image Height")
                        Spacer()
                        Text("\(state.estimatedHeight) px")
                    }
                    Slider(value: Binding(
                        get: { Double(state.estimatedHeight) },
                        set: { state.updateWidthFromHeight(Int($0)) }
                    ), in: state.minHeight...state.maxHeight, step: 10.0)
                }

                HStack {
                    Text("Grid Spacing")
                    Spacer()
                    Text("\(state.gridSpacing) px")
                }
                Slider(value: Binding(
                    get: { Double(state.gridSpacing) },
                    set: { state.gridSpacing = Int($0) }
                ), in: 0...50, step: 1.0)
            }
        }
        .monoFont()
    }
}
