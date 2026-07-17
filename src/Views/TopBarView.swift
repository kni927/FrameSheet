import SwiftUI

// MARK: - Subviews

struct TopBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            Image(systemName: "photo.stack")
                .font(.title3)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("FrameSheet")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                if let video = state.selectedVideo {
                    Text(video.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                } else {
                    Text("No video selected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // Zoom Controls
            if state.previewImage != nil {
                HStack(spacing: 6) {
                    Button(action: { state.zoomScale = max(0.1, state.zoomScale - 0.1) }) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("\(Int(state.zoomScale * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 42)
                        .multilineTextAlignment(.center)

                    Button(action: { state.zoomScale = min(3.0, state.zoomScale + 0.1) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("100%") {
                        state.zoomScale = 1.0
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Fit") {
                        state.fitToScreen()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.trailing, 10)
            }

            // Console toggle
            Button(action: { withAnimation { state.showConsole.toggle() } }) {
                Image(systemName: "terminal")
                    .foregroundColor(state.showConsole ? .accentColor : .gray)
            }
            .buttonStyle(.plain)
            .help("Toggle console output")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            VStack {
                Spacer()
                Divider()
            }
        )
    }
}
