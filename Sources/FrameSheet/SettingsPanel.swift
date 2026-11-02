import FrameSheetCore
import SwiftUI

/// Right sidebar (§6), grid parts: stats and columns of the current sheet,
/// styling, frame info, thumbnail cache and ffmpeg. Header, output, naming,
/// face, timeline and experimental sections come with their TASKs.
struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.space3) {
                if let sheet = model.currentSheet {
                    GridSection(sheet: sheet)
                }
                StylingSection()
                FrameInfoSection()
                CacheSection()
                Card(title: "ffmpeg") { FFmpegRow() }
            }
            .padding(Theme.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.crust)
        .font(Theme.bodySm)
        .foregroundStyle(Theme.text)
    }
}

extension AppModel {
    /// A binding to one global setting (not undoable).
    func setting<T>(_ keyPath: WritableKeyPath<FrameSheetCore.Settings, T>) -> Binding<T> {
        Binding(
            get: { self.library.settings[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

/// A slider with its label and value on one line above it.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.rounded()))")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textMuted)
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                .controlSize(.small)
        }
    }
}

private struct GridSection: View {
    @Environment(AppModel.self) private var model
    let sheet: Sheet
    @State private var changeCount = false
    @State private var rows = 4.0
    @State private var isDragging = false

    var body: some View {
        Card(title: "Grid") {
            Text(GridLayout.statsLine(columns: sheet.columnCount, thumbCount: sheet.visibleThumbs.count))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
            LabeledSlider(
                title: "Columns",
                value: Binding(
                    get: { Double(sheet.columnCount) },
                    set: { model.setColumnsLive(Int($0.rounded()), editing: isDragging) }),
                range: 1...20
            ) { editing in
                isDragging = editing
                if !editing { model.endColumnsDrag() }
            }
            Toggle("Change thumb count", isOn: $changeCount.animation(.easeOut(duration: 0.15)))
                .toggleStyle(.checkbox)
                .onChange(of: changeCount) { _, on in
                    if on { rows = Double(defaultRows) }
                }
            if changeCount {
                LabeledSlider(title: "Rows", value: $rows, range: 1...20)
                let count = sheet.columnCount * Int(rows.rounded())
                Label(
                    "Applying replaces the \(sheet.thumbs.count) thumbs of this sheet with \(count) new ones.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Apply") {
                        model.applyThumbCount(columns: sheet.columnCount, rows: Int(rows.rounded()))
                        changeCount = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .onChange(of: sheet.id) { changeCount = false }
    }

    private var defaultRows: Int {
        let c = max(1, sheet.columnCount)
        return min(20, max(1, (sheet.visibleThumbs.count + c - 1) / c))
    }
}

private struct StylingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Styling") {
            LabeledSlider(title: "Grid margin", value: model.setting(\.marginSlider), range: 0...20)
            Toggle("Rounded corners", isOn: model.setting(\.roundedCorners))
            Toggle("Show hidden thumbs", isOn: model.setting(\.showHiddenThumbs))
        }
        .toggleStyle(.checkbox)
    }
}

private struct FrameInfoSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Frame info") {
            Picker("Frame info", selection: model.setting(\.frameInfo)) {
                Text("Frames").tag(FrameInfo.frames)
                Text("Timecode").tag(FrameInfo.timecode)
                Text("Hide").tag(FrameInfo.hidden)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ColorRow(title: "Font colour", value: model.setting(\.frameInfoColor))
            ColorRow(title: "Background colour", value: model.setting(\.frameInfoBackground))
            Picker("Position", selection: model.setting(\.frameInfoPosition)) {
                ForEach(FrameInfoPosition.allCases, id: \.self) { position in
                    Text(position.label).tag(position)
                }
            }
            LabeledSlider(title: "Size", value: model.setting(\.frameInfoSize), range: 1...100)
            LabeledSlider(title: "Margin", value: model.setting(\.frameInfoMargin), range: 0...50)
        }
    }
}

/// Catppuccin swatches, transparent, and the system colour picker for any
/// other colour.
private struct ColorRow: View {
    let title: String
    @Binding var value: RGBA

    private let columns = Array(repeating: GridItem(.fixed(18), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space1) {
            HStack {
                Text(title)
                Spacer()
                ColorPicker(title, selection: Binding(get: { Color(value) }, set: { value = RGBA($0) }))
                    .labelsHidden()
                    .help("Any colour")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Theme.frameInfoPresets, id: \.name) { preset in
                    Swatch(rgba: preset.rgba, selected: value == preset.rgba) { value = preset.rgba }
                        .help(preset.name)
                }
                Swatch(rgba: .clear, selected: value.alpha == 0) { value = .clear }
                    .help("Transparent")
            }
        }
    }
}

private struct Swatch: View {
    let rgba: RGBA
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(rgba))
                if rgba.alpha == 0 {
                    // Transparent: an empty circle with a slash.
                    Path { p in
                        p.move(to: CGPoint(x: 4, y: 14))
                        p.addLine(to: CGPoint(x: 14, y: 4))
                    }
                    .stroke(Theme.danger, lineWidth: 1.5)
                }
                Circle().strokeBorder(selected ? Theme.accent : Theme.borderControl, lineWidth: selected ? 2 : 1)
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CacheSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Thumbnail cache") {
            let limit = model.library.settings.thumbnailCacheMB
            Stepper(
                value: Binding(get: { limit }, set: { model.setCacheLimit($0) }), in: 64...8192, step: 64
            ) {
                HStack {
                    Text("Memory limit")
                    Spacer()
                    Text("\(limit) MB")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            Button("Clear thumbnail cache") { model.clearThumbnailCache() }
                .controlSize(.small)
            Text("Decoded display-size thumbnails kept in memory.")
                .font(Theme.caption)
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
                if model.library.settings.ffmpegPath != nil {
                    Button("Search automatically") { model.setFFmpegPath(nil) }
                }
            }
            .controlSize(.small)
            .padding(.top, Theme.space1)
            Text("Used for files AVFoundation cannot decode, such as WebM and MKV.")
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textMuted)
    }
}
