import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Custom Segmented Picker for Tab Selectors
            HStack(spacing: 4) {
                TabButton(iconName: "square.grid.3x3", isSelected: state.activeTab == "layout", helpText: "Layout Settings") {
                    state.activeTab = "layout"
                }
                TabButton(iconName: "paintbrush", isSelected: state.activeTab == "style", helpText: "Style Settings") {
                    state.activeTab = "style"
                }
                TabButton(iconName: "clock", isSelected: state.activeTab == "frames", helpText: "Frame Settings") {
                    state.activeTab = "frames"
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Tab Contents
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.activeTab == "layout" {
                        LayoutTab()
                    } else if state.activeTab == "style" {
                        StyleTab()
                    } else if state.activeTab == "frames" {
                        FramesTab()
                    }
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
