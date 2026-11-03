import AppKit
import FrameSheetCore
import SwiftUI

/// Right sidebar (§6), grid parts: stats and columns of the current sheet,
/// styling and frame info. The thumbnail cache and ffmpeg live in the
/// Settings window; header, output, naming, face, timeline and experimental
/// sections come with their TASKs.
struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let sheet = model.currentSheet {
                    GridSection(sheet: sheet)
                }
                StylingSection()
                FrameInfoSection()
            }
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

/// A slider with its label on the left and its value right-aligned above it.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var help: String?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(title) {
                Text("\(Int(value.rounded()))\(unit)")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textMuted)
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .help(help ?? title)
        }
    }
}

/// An on/off setting: label left, switch right.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        PanelRow(title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(help ?? title)
        }
    }
}

private struct GridSection: View {
    @Environment(AppModel.self) private var model
    let sheet: Sheet
    @State private var isDragging = false
    @State private var isDraggingRows = false
    /// Rows of the pending thumb count (columns × rows); nil until the
    /// Thumbs slider moves.
    @State private var newRows: Int?

    var body: some View {
        let columns = sheet.columnCount
        let count = sheet.visibleThumbs.count
        let rows = GridLayout.rows(columns: columns, thumbCount: count)
        let pendingRows = newRows ?? max(1, rows)
        let newCount = columns * pendingRows
        PanelSection(title: "Grid") {
            // The stats (§6) as numbers over labels; no "×" or "=", since
            // hidden thumbs make columns × rows differ from the count.
            HStack(spacing: 0) {
                Stat(value: columns, label: "columns")
                Stat(value: rows, label: "rows")
                Stat(value: count, label: "count")
            }
            .padding(.bottom, Theme.space1)
            LabeledSlider(
                title: "Columns",
                value: Binding(
                    get: { Double(columns) },
                    set: { model.setColumnsLive(Int($0.rounded()), editing: isDragging) }),
                range: 1...20, help: "Columns of this sheet"
            ) { editing in
                isDragging = editing
                if !editing { model.endColumnsDrag() }
            }
            // Rearranges only: the columns follow from the rows.
            LabeledSlider(
                title: "Rows",
                value: Binding(
                    get: { Double(max(1, rows)) },
                    set: { model.setRowsLive(Int($0.rounded()), editing: isDraggingRows) }),
                range: 1...20, help: "Rows of this sheet; the columns follow and the thumb count stays"
            ) { editing in
                isDraggingRows = editing
                if !editing { model.endColumnsDrag() }
            }
            // Steps of one row: the count is always columns × rows.
            LabeledSlider(
                title: "Thumbs",
                value: Binding(
                    get: { Double(newCount) },
                    set: { newRows = max(1, Int(($0 / Double(columns)).rounded())) }),
                range: Double(columns)...Double(columns * 20), step: Double(columns),
                help: "New thumb count: \(columns) columns × \(pendingRows) rows")
            HStack {
                Spacer(minLength: 0)
                // The Apply action: recaptures between the first and last
                // visible frames as one undo step.
                Button("Change thumb count") {
                    model.applyThumbCount(columns: columns, rows: pendingRows)
                    newRows = nil
                }
                .controlSize(.small)
                // Until the slider moves nothing is chosen: a partly filled
                // last row would otherwise offer to fill it at rest.
                .disabled(newRows == nil || newCount == count)
                .help("Replaces \(count) thumbs with \(newCount); ⌘Z undoes")
            }
        }
        .onChange(of: sheet.id) { newRows = nil }
        .onChange(of: columns) { newRows = nil }
    }
}

/// A large number over a small muted label, one of three equal columns.
private struct Stat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(Theme.statValue)
                .foregroundStyle(Theme.text)
            Text(label)
                .font(Theme.panelCaption)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct StylingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelSection(title: "Styling") {
            MarginRows(
                horizontal: \.marginHorizontal, vertical: \.marginVertical, linkedKey: \.marginsLinked,
                range: 0...20, horizontalHelp: "Space between columns", verticalHelp: "Space between rows")
            LabeledSlider(
                title: "Corner radius", value: model.setting(\.cornerRadius), range: 0...20, unit: " %",
                help: "Corner radius, % of thumb width (0 = square)")
            SwitchRow(title: "Show hidden thumbs", isOn: model.setting(\.showHiddenThumbs), help: "Show hidden thumbs dimmed")
        }
    }
}

/// Horizontal and vertical margins with a link that moves them together;
/// used for the grid margins and the frame info margins.
private struct MarginRows: View {
    @Environment(AppModel.self) private var model
    let horizontal: WritableKeyPath<FrameSheetCore.Settings, Double>
    let vertical: WritableKeyPath<FrameSheetCore.Settings, Double>
    let linkedKey: WritableKeyPath<FrameSheetCore.Settings, Bool>
    let range: ClosedRange<Double>
    let horizontalHelp: String
    let verticalHelp: String

    var body: some View {
        let linked = model.library.settings[keyPath: linkedKey]
        HStack(alignment: .center, spacing: Theme.space2) {
            VStack(alignment: .leading, spacing: Theme.space2) {
                LabeledSlider(
                    title: "Horizontal margin", value: margin(horizontal, other: vertical),
                    range: range, help: horizontalHelp)
                LabeledSlider(
                    title: "Vertical margin", value: margin(vertical, other: horizontal),
                    range: range, help: verticalHelp)
            }
            Button {
                model.updateSettings { s in
                    s[keyPath: linkedKey].toggle()
                    // Linking aligns the vertical margin to the horizontal one.
                    if s[keyPath: linkedKey] { s[keyPath: vertical] = s[keyPath: horizontal] }
                }
            } label: {
                Image(systemName: linked ? "link" : "link.badge.plus")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(ToolbarIconStyle(selected: linked))
            .help(linked ? "Margins linked (click to unlink)" : "Link margins")
            .accessibilityLabel("Link margins")
            .accessibilityAddTraits(linked ? .isSelected : [])
        }
    }

    /// One margin; while linked, the other follows.
    private func margin(
        _ key: WritableKeyPath<FrameSheetCore.Settings, Double>,
        other: WritableKeyPath<FrameSheetCore.Settings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.library.settings[keyPath: key] },
            set: { value in
                model.updateSettings { s in
                    s[keyPath: key] = value
                    if s[keyPath: linkedKey] { s[keyPath: other] = value }
                }
            })
    }
}

private struct FrameInfoSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelSection(title: "Frame info") {
            Picker("Frame info", selection: model.setting(\.frameInfo)) {
                Text("Frames").tag(FrameInfo.frames)
                Text("Timecode").tag(FrameInfo.timecode)
                Text("Hide").tag(FrameInfo.hidden)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Frame number, timecode or none")
            PanelRow("Font") {
                FontFamilyPicker(selection: model.setting(\.frameInfoFontFamily))
            }
            LabeledSlider(
                title: "Size", value: model.setting(\.frameInfoSize), range: 1...100,
                help: "Relative to thumb height")
            ColorRow(title: "Colour", value: model.setting(\.frameInfoColor), keepsOpacity: false)
            ColorRow(title: "Background", value: model.setting(\.frameInfoBackground), keepsOpacity: true)
            LabeledSlider(
                title: "Background opacity",
                value: Binding(
                    get: { model.library.settings.frameInfoBackground.alpha * 100 },
                    set: { v in model.updateSettings { $0.frameInfoBackground.alpha = v / 100 } }),
                range: 0...100, unit: " %", help: "Background opacity")
            PanelRow("Position") {
                Picker("Position", selection: model.setting(\.frameInfoPosition)) {
                    ForEach(FrameInfoPosition.allCases, id: \.self) { position in
                        Text(position.label).tag(position)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Where on the thumb")
            }
            MarginRows(
                horizontal: \.frameInfoMarginHorizontal, vertical: \.frameInfoMarginVertical,
                linkedKey: \.frameInfoMarginsLinked, range: 0...50,
                horizontalHelp: "Distance from the left or right edge",
                verticalHelp: "Distance from the top or bottom edge")
        }
    }
}

/// The system designs first, then every installed font family.
private struct FontFamilyPicker: View {
    @Binding var selection: String

    /// Read once; the list does not change while the app runs often enough
    /// to matter.
    @MainActor private static let installed = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Picker("Font", selection: $selection) {
            ForEach(FrameInfoFamily.systemFamilies, id: \.family) { item in
                Text(item.label).tag(item.family)
            }
            Divider()
            // A chosen family that is no longer installed stays selectable.
            if !FrameInfoFamily.isSystem(selection), !Self.installed.contains(selection) {
                Text(selection).tag(selection)
            }
            ForEach(Self.installed, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 170)
        .help("Frame info font")
    }
}

/// A few Catppuccin swatches, Transparent, and the system colour picker for
/// any other colour. With `keepsOpacity` a new colour keeps the opacity set
/// by the slider (the opacity of Transparent is restored to 100 %).
private struct ColorRow: View {
    let title: String
    @Binding var value: RGBA
    let keepsOpacity: Bool

    var body: some View {
        PanelRow(title) {
            HStack(spacing: Theme.space1) {
                ForEach(Theme.frameInfoPresets, id: \.name) { preset in
                    Swatch(rgba: preset.rgba, selected: value.alpha > 0 && sameColour(value, preset.rgba)) {
                        choose(preset.rgba)
                    }
                    .help(preset.name)
                }
                Swatch(rgba: .clear, selected: value.alpha == 0) { value = .clear }
                    .help("Transparent")
                ColorPicker(
                    title,
                    selection: Binding(get: { Color(value).opacity(1) }, set: { choose(RGBA($0)) }),
                    supportsOpacity: false
                )
                .labelsHidden()
                .help("Any colour")
            }
        }
    }

    private func choose(_ colour: RGBA) {
        var new = colour
        new.alpha = keepsOpacity && value.alpha > 0 ? value.alpha : 1
        value = new
    }

    private func sameColour(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002
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
