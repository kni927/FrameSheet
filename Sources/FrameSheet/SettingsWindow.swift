import FrameSheetCore
import SwiftUI

/// The Settings window (⌘,): settings that are set once rather than per
/// sheet, kept out of the right panel so it stays short (owner, 2026-11-03).
struct SettingsWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CacheSection()
            PanelSection(title: "ffmpeg") { FFmpegRow() }
        }
        .padding(.vertical, Theme.space2)
        .frame(width: 460, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.base)
        .font(Theme.bodySm)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }
}

private struct CacheSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelSection(title: "Thumbnail cache") {
            let limit = model.library.settings.thumbnailCacheMB
            PanelRow("Memory limit") {
                Text("\(limit) MB")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textMuted)
                Stepper(
                    "Memory limit", value: Binding(get: { limit }, set: { model.setCacheLimit($0) }),
                    in: 64...8192, step: 64
                )
                .labelsHidden()
                .help("Memory for decoded thumbs")
            }
            PanelRow("Cached thumbnails") {
                Button("Clear") { model.clearThumbnailCache() }
                    .controlSize(.small)
                    .help("Clear thumbnail cache")
            }
            Text("Decoded display-size thumbnails kept in memory.")
                .font(Theme.panelCaption)
                .foregroundStyle(Theme.textMuted)
        }
    }
}

private struct FFmpegRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space1) {
            if model.isFindingFFmpeg {
                ProgressView().controlSize(.small)
            } else if let tools = model.ffmpeg?.tools {
                Text(tools.ffmpeg.path)
                    .font(Theme.mono(12))
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.text)
                Text("Version \(tools.version) · \(tools.source.rawValue)")
                if tools.ffprobe == nil {
                    Label("ffprobe is missing next to ffmpeg", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            } else {
                Label("Not found", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
            ForEach(model.ffmpeg?.notes ?? [], id: \.self) { note in
                Text(note).foregroundStyle(Theme.warning)
            }
            HStack {
                Button("Choose…") { model.chooseFFmpeg() }
                    .help("Pick an ffmpeg executable")
                if model.library.settings.ffmpegPath != nil {
                    Button("Search automatically") { model.setFFmpegPath(nil) }
                        .help("Forget the chosen path")
                }
            }
            .controlSize(.small)
            .padding(.top, Theme.space1)
            Text("Used for files AVFoundation cannot decode, such as WebM and MKV.")
        }
        .font(Theme.panelCaption)
        .foregroundStyle(Theme.textMuted)
    }
}
