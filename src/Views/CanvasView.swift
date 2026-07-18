import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Canvas Preview

struct CanvasView: View {
    @EnvironmentObject var state: AppState
    @State private var isTargeted = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    if let video = state.selectedVideo {
                        // Toolbar actions for loaded video
                        HStack {
                            // Video Info Card
                            HStack(spacing: 10) {
                                Image(systemName: "video.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(video.name)
                                            .fontWeight(.bold)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(video.formattedSize)
                                            .foregroundColor(.gray)
                                    }
                                    Text("Resolution: \(video.width)x\(video.height) | Duration: \(video.formattedDuration) | Codec: \(video.codec)")
                                        .foregroundColor(.gray)
                                }
                                .font(.system(size: 10, design: .monospaced))
                            }

                            Spacer()

                            // Unhide-all action (Phase 3a Stage B)
                            if state.hiddenCount > 0 {
                                Button(action: { state.resetHidden() }) {
                                    Label("Unhide All (\(state.hiddenCount))", systemImage: "eye")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Reset all hidden thumbnails")
                            }

                            // Reveal file button
                            Button(action: {
                                NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: "")
                            }) {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                        .overlay(
                            VStack {
                                Spacer()
                                Divider()
                            }
                        )
                    }

                    // Image Preview Area
                    ZStack {
                        if state.isEstimatingDuration {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Estimating duration…")
                                    .foregroundColor(.gray)
                                Text("This file's metadata has no duration; scanning packets.")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Button("Cancel") {
                                    state.cancelGeneration()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .monoFont()
                        } else if state.isGenerating {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Extracting frames and generating contact sheet...")
                                    .foregroundColor(.gray)
                            }
                            .monoFont()
                        } else if let dp = state.displayParams, !state.thumbnails.isEmpty {
                            // Addressable grid (Phase 3a): one view per
                            // thumbnail, same geometry as the exported sheet
                            ScrollView([.horizontal, .vertical]) {
                                ThumbnailGridView(params: dp)
                                    // Checkerboard behind the sheet so a
                                    // transparent background is visible
                                    .background(
                                        state.backgroundAlpha < 1.0
                                            ? AnyView(CheckerboardBackground())
                                            : AnyView(Color.clear)
                                    )
                                    .padding(20)
                            }
                        } else if let image = state.previewImage {
                            // Fallback: flattened composite (e.g. cell images
                            // unavailable)
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(
                                        width: CGFloat(state.imageWidth) * state.zoomScale,
                                        height: CGFloat(state.imageWidth) * image.aspectRatio * state.zoomScale
                                    )
                                    .background(
                                        state.backgroundAlpha < 1.0
                                            ? AnyView(CheckerboardBackground())
                                            : AnyView(Color.clear)
                                    )
                                    .padding(20)
                            }
                        } else {
                            // Drag & drop placeholder
                            VStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 40))
                                    .foregroundColor(isTargeted ? .accentColor : .secondary)
                                    .scaleEffect(isTargeted ? 1.05 : 1.0)
                                    .animation(.spring(), value: isTargeted)

                                Text("Drag & Drop Video File Here")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))

                                Text("Or click below to browse")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Button("Choose Video File") {
                                    state.openVideoPanel()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(state.isGenerating)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Export / Clipboard action bar
                    if state.previewImage != nil && !state.isGenerating {
                        Divider()
                        HStack(spacing: 12) {
                            Button(action: { state.copyToClipboard() }) {
                                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .keyboardShortcut("c", modifiers: .command)

                            Button(action: { state.quickSaveToMovieFolder() }) {
                                Label("Save to Movie Folder", systemImage: "folder.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Save directly next to the source video using the filename template")

                            Button(action: { state.saveImageAs() }) {
                                Label("Save Image As...", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut("s", modifiers: .command)
                        }
                        .padding(10)
                        .background(Color(NSColor.windowBackgroundColor))
                    }
                }

                // FFmpeg missing notice. Since the AVFoundation backend
                // became primary, ffmpeg is optional (needed only for
                // WebM/MKV and other non-native formats) — the notice is
                // informational and dismissible, shown once before any
                // video is loaded.
                if !state.isFFmpegInstalled && !state.isCheckingDependencies
                    && state.selectedVideo == nil && !state.ffmpegNoticeDismissed {
                    Color.black.opacity(0.55)
                        .edgesIgnoringSafeArea(.all)

                    VStack(spacing: 16) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)

                        Text("FFmpeg Not Found")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)

                        Text("mp4 / mov / m4v work without it (native macOS decoder).\nWebM, MKV and other formats need FFmpeg:")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)

                        Text("brew install ffmpeg")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)

                        VStack(alignment: .leading, spacing: 6) {
                            DependencyRow(title: "ffmpeg", path: state.ffmpegPath.isEmpty ? "Missing" : state.ffmpegPath)
                            DependencyRow(title: "ffprobe", path: state.ffprobePath.isEmpty ? "Missing" : state.ffprobePath)
                        }
                        .frame(width: 320)

                        HStack(spacing: 12) {
                            Button(action: { state.checkDependencies() }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(state.isCheckingDependencies)

                            Button("Continue without FFmpeg") {
                                state.ffmpegNoticeDismissed = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(24)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(radius: 12)
                    .frame(maxWidth: 400)
                }

                // Drop-target highlight when dragging over a loaded video
                if isTargeted && state.selectedVideo != nil {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            // Accept drops in every state: dropping a new file replaces the
            // currently loaded video (same path as File > Open).
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        DispatchQueue.main.async {
                            state.loadVideo(url: url)
                        }
                    }
                }
                return true
            }
            .onAppear {
                state.containerWidth = geometry.size.width
                state.containerHeight = geometry.size.height
            }
            .onChange(of: geometry.size.width) { newWidth in
                state.containerWidth = newWidth
            }
            .onChange(of: geometry.size.height) { newHeight in
                state.containerHeight = newHeight
            }
        }
    }
}
