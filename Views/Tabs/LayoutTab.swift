import SwiftUI

// MARK: - Tab Panels

struct LayoutTab: View {
    @EnvironmentObject var state: AppState

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

            Text("Output Options")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            VStack(alignment: .leading, spacing: 8) {
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
