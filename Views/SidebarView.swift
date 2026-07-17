import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Single scrolling settings column (MoviePrint-style), flattened
            // from the former Layout/Style/Frames tabs. Order: Grid
            // Dimensions -> Output Options -> Font -> Colors -> Visual
            // Elements -> Auto Sampling Range.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LayoutTab()
                    Divider()
                    StyleTab()
                    Divider()
                    FramesTab()
                }
                .padding(12)
            }

            Spacer()

            Divider()

            // Bottom Action Area in Sidebar
            VStack(spacing: 8) {
                if state.isGenerating || state.isEstimatingDuration {
                    Button(action: {
                        state.cancelGeneration()
                    }) {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("Cancel")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                } else {
                    Button(action: {
                        state.generateContactSheet()
                    }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Generate")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.selectedVideo == nil || !state.isFFmpegInstalled)
                }
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}
