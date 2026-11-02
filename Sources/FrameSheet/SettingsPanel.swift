import FrameSheetCore
import SwiftUI

/// Right sidebar (§6). Only the ffmpeg row exists yet; the rest of the
/// panel comes with the features it controls.
struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text("More settings come with later versions.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Divider()
                FFmpegRow()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.sidebarBackground)
    }
}

private struct FFmpegRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ffmpeg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            if model.isFindingFFmpeg {
                ProgressView().controlSize(.small)
            } else if let tools = model.ffmpeg?.tools {
                Text(tools.ffmpeg.path)
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.primaryText)
                Text("Version \(tools.version) · \(tools.source.rawValue)")
                if tools.ffprobe == nil {
                    Text("ffprobe is missing next to ffmpeg").foregroundStyle(Theme.peach)
                }
            } else {
                Text("Not found").foregroundStyle(Theme.peach)
            }
            ForEach(model.ffmpeg?.notes ?? [], id: \.self) { note in
                Text(note).foregroundStyle(Theme.peach)
            }
            HStack {
                Button("Choose…") { model.chooseFFmpeg() }
                if model.library.settings.ffmpegPath != nil {
                    Button("Search automatically") { model.setFFmpegPath(nil) }
                }
            }
            .padding(.top, 4)
            Text("Used for files AVFoundation cannot decode, such as WebM and MKV.")
                .foregroundStyle(Theme.overlay1)
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
    }
}
