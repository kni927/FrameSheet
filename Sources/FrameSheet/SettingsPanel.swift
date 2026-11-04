import AppKit
import FrameSheetCore
import SwiftUI

/// Right sidebar (§6): the grid section (stats, columns, rows) or, for a
/// sheet in timeline view, the timeline section (stats, minutes per row,
/// natural flow, shot detection threshold); styling, the thumb label,
/// output, the naming scheme, face detection and the experimental options.
/// The thumbnail cache and ffmpeg live in the Settings window.
struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let sheet = model.currentSheet {
                    if model.isTimeline(sheet) {
                        TimelineSection(sheet: sheet)
                    } else {
                        GridSection(sheet: sheet)
                    }
                }
                StylingSection()
                FrameInfoSection()
                OutputSection()
                NamingSection()
                FaceDetectionSection()
                ExperimentalSection()
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
    /// The value as shown; whole numbers with `unit` by default.
    var format: ((Double) -> String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(title) {
                Text(format?(value) ?? "\(Int(value.rounded()))\(unit)")
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

    var body: some View {
        let columns = sheet.columnCount
        let count = sheet.visibleThumbs.count
        let rows = GridLayout.rows(columns: columns, thumbCount: count)
        let targetRows = model.targetRows(of: sheet)
        let pending = model.hasRowsTarget(sheet)
        let newCount = columns * targetRows
        // Automatic IN/OUT under More (owner, 2026-11-03).
        PanelSection(title: "Grid", expandedKey: "grid") {
            // The stats (§6) as numbers over labels; no "×" or "=", since
            // hidden thumbs make columns × rows differ from the count. A
            // pending target shows its rows and columns × rows.
            HStack(spacing: 0) {
                Stat(value: columns, label: "columns")
                Stat(value: pending ? targetRows : rows, label: "rows")
                Stat(value: pending ? newCount : count, label: "count")
            }
            .padding(.bottom, Theme.space1)
            // Rearranges live: the count stays and the rows follow.
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
            // A target only: extra rows show as empty cells; Replace applies it.
            LabeledSlider(
                title: "Rows",
                value: Binding(
                    get: { Double(targetRows) },
                    set: { model.setTargetRows(Int($0.rounded())) }),
                range: 1...Double(max(20, targetRows)),
                help: "Target rows; Replace recaptures columns × rows thumbs")
            HStack {
                Spacer(minLength: 0)
                // Recaptures between the first and last visible frames as one
                // undo step.
                Button("Replace") {
                    model.applyThumbCount(columns: columns, rows: targetRows)
                }
                .controlSize(.small)
                .disabled(newCount == count)
                .help("Replace \(count) thumbs with \(columns) × \(targetRows) = \(newCount); ⌘Z undoes")
            }
        } more: {
            AutomaticInOutRows()
        }
    }
}

/// Automatic IN/OUT (§10): the switch for movies added from now on, the
/// brightness threshold, and Apply for the movie shown now.
private struct AutomaticInOutRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SwitchRow(
            title: "Automatic IN/OUT", isOn: model.setting(\.automaticInOut),
            help: "Skip dark frames at the start and end of movies added from now on")
        LabeledSlider(
            title: "Brightness threshold", value: model.setting(\.automaticInOutThreshold),
            range: Defaults.automaticInOutThresholdRange,
            help: "Frames darker than this count as black at the start and end")
        // The switch acts on movies added later; Apply runs the same
        // detection on the movie shown now.
        HStack {
            Spacer(minLength: 0)
            Button(model.isDetectingInOut ? "Detecting…" : "Apply") {
                model.applyAutomaticInOut()
            }
            .controlSize(.small)
            .disabled(model.isDetectingInOut || model.currentSheet?.type != .interval)
            .help("Apply IN/OUT to the current sheet")
        }
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
        let showHeader = model.library.settings.showHeader
        let timeline = model.currentSheet.map(model.isTimeline) ?? false
        // Show header always (grid view; the timeline print has no header);
        // the rest under More (owner, 2026-11-03).
        PanelSection(title: "Styling", expandedKey: "styling") {
            if timeline {
                TimelineStylingRows()
            } else {
                SwitchRow(
                    title: "Show header", isOn: model.setting(\.showHeader),
                    help: "File name, details and timeline above the thumbs")
            }
        } more: {
            if !timeline { headerRows(enabled: showHeader) }
            MarginRows(
                horizontal: \.marginHorizontal, vertical: \.marginVertical, linkedKey: \.marginsLinked,
                range: 0...20, horizontalHelp: "Space between columns", verticalHelp: "Space between rows")
            LabeledSlider(
                title: "Corner radius", value: model.setting(\.cornerRadius), range: 0...20, unit: " %",
                help: "Corner radius, % of thumb width (0 = square)")
            SwitchRow(title: "Show hidden thumbs", isOn: model.setting(\.showHiddenThumbs), help: "Show hidden thumbs dimmed")
        }
    }

    /// The header's parts (grid view).
    private func headerRows(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            SwitchRow(title: "File path", isOn: model.setting(\.showPathInHeader), help: "Movie's folder in the header")
            SwitchRow(
                title: "File details", isOn: model.setting(\.showDetailsInHeader),
                help: "Duration, fps, size, file size and codec in the header")
            SwitchRow(
                title: "Timeline", isOn: model.setting(\.showTimelineInHeader),
                help: "Mini timeline with the thumbs' positions in the header")
            PanelRow("Alignment") {
                Picker("Alignment", selection: model.setting(\.headerAlignment)) {
                    ForEach(HeaderAlignment.allCases, id: \.self) { alignment in
                        Text(alignment.label).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Header text at the right or left")
            }
        }
        .padding(.leading, Theme.space4)
        .disabled(!enabled)
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
        let mode = model.library.settings.frameInfo
        // The mode and its format always; the rest under More (owner,
        // 2026-11-03). Named "Thumb label" in the panel (owner, 2026-11-03);
        // the settings keep their `frameInfo` names.
        PanelSection(title: "Thumb label", expandedKey: "frameInfo") {
            Picker("Thumb label", selection: model.setting(\.frameInfo)) {
                Text("Frames").tag(FrameInfo.frames)
                Text("Timecode").tag(FrameInfo.timecode)
                Text("Hide").tag(FrameInfo.hidden)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Frame number, timecode or none")
            PanelRow("Format") {
                if mode == .timecode {
                    Picker("Format", selection: model.setting(\.frameInfoTimecodeFormat)) {
                        ForEach(TimecodeFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Timecode format on thumbs (file names keep HH_MM_SS_FF)")
                } else {
                    Picker("Format", selection: model.setting(\.frameInfoFrameFormat)) {
                        ForEach(FrameNumberFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Frame number, or with the movie's last frame number (9920 / 17604)")
                    .disabled(mode == .hidden)
                }
            }
        } more: {
            PanelRow("Font") {
                FontFamilyPicker(selection: model.setting(\.frameInfoFontFamily))
            }
            LabeledSlider(
                title: "Size", value: model.setting(\.frameInfoSize), range: 1...100,
                help: "Relative to thumb height")
            LabeledSlider(
                title: "Max size", value: model.setting(\.frameInfoMaxSize), range: Defaults.frameInfoMaxSizeRange,
                unit: " pt", help: "Largest label: pt per 1000 pt of print width")
            ColorRow(title: "Color", value: model.setting(\.frameInfoColor), keepsOpacity: false)
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

/// A few Catppuccin swatches, Transparent, and the system color picker for
/// any other color. With `keepsOpacity` a new color keeps the opacity set
/// by the slider (the opacity of Transparent is restored to 100 %).
private struct ColorRow: View {
    let title: String
    @Binding var value: RGBA
    let keepsOpacity: Bool
    var help: String?

    var body: some View {
        PanelRow(title) {
            HStack(spacing: Theme.space1) {
                ForEach(Theme.frameInfoPresets, id: \.name) { preset in
                    Swatch(rgba: preset.rgba, selected: value.alpha > 0 && sameColor(value, preset.rgba)) {
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
                .help("Any color")
            }
        }
        .help(help ?? title)
    }

    private func choose(_ color: RGBA) {
        var new = color
        new.alpha = keepsOpacity && value.alpha > 0 ? value.alpha : 1
        value = new
    }

    private func sameColor(_ a: RGBA, _ b: RGBA) -> Bool {
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

/// Output (§6): where and how Save Sheet, Save thumb and Export JSON
/// write.
private struct OutputSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.library.settings
        let folder = model.outputFolder(for: model.currentFile)
        let isPNG = settings.outputFormat == .png
        // Folder, size and format always; the rest under More (owner,
        // 2026-11-03).
        PanelSection(title: "Output", expandedKey: "output") {
            PanelRow("Folder") {
                Text(settings.outputSameFolderAsMovie
                     ? "Movie's folder" : PathDisplay.abbreviatingHome(folder.path))
                    .font(Theme.panelCaption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                Button("Change…") { model.chooseOutputFolder() }
                    .controlSize(.small)
                    .help("Choose the folder for saved files")
                    .disabled(settings.outputSameFolderAsMovie)
            }
            SwitchRow(
                title: "Same as movie file", isOn: model.setting(\.outputSameFolderAsMovie),
                help: "Save next to the movie instead")
            SizeRows()
            PanelRow("Format") {
                FormatPicker(selection: model.setting(\.outputFormat), help: "Image format of the print")
            }
        } more: {
            LabeledSlider(
                title: "Quality", value: intSetting(\.outputQuality), range: 0...100,
                help: "JPG quality of the print")
                .disabled(isPNG)
            ColorRow(
                title: "Background", value: model.setting(\.outputBackground), keepsOpacity: false,
                help: "Print background; transparency applies to PNG only (JPG saves it opaque)")
            SwitchRow(
                title: "Overwrite", isOn: model.setting(\.overwrite),
                help: "Replace a file of the same name; off adds \" edit N\"")
            SwitchRow(
                title: "Also save each thumb", isOn: model.setting(\.includeIndividualThumbs),
                help: "Saves every visible thumb as its own image in a folder named after the sheet image")
            SwitchRow(
                title: "Embed frame numbers", isOn: model.setting(\.embedFrameNumbers),
                help: "PNG only: embed the frames, columns and transform so the PNG can be imported")
                .disabled(!isPNG)
            SwitchRow(
                title: "Embed file path", isOn: model.setting(\.embedFilePath),
                help: "PNG only: embed the movie's path")
                .disabled(!isPNG)
            SwitchRow(
                title: "Include face rectangles", isOn: model.setting(\.includeFaceRectanglesInPrint),
                help: "Draw the face rectangles of faces sheets in saved sheets")
            SwitchRow(
                title: "Open Finder after saving", isOn: model.setting(\.openFinderAfterSaving),
                help: "Show the saved file in the Finder")
            PanelRow("Thumb format") {
                FormatPicker(selection: model.setting(\.thumbFormat), help: "Image format of saved thumbs")
            }
            LabeledSlider(
                title: "Thumb quality", value: intSetting(\.thumbQuality), range: 0...100,
                help: "JPG quality of saved thumbs")
                .disabled(settings.thumbFormat == .png)
        }
    }

    private func intSetting(_ key: WritableKeyPath<FrameSheetCore.Settings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.library.settings[keyPath: key]) },
            set: { value in model.updateSettings { $0[keyPath: key] = Int(value.rounded()) } })
    }
}

/// Output size: 1024–16384 px in steps of 1024, or max; the label gives
/// the size the current sheet would be saved at.
private struct SizeRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.library.settings
        // In timeline view the size is the print's height (§6).
        let timeline = model.currentSheet.map(model.isTimeline) ?? false
        let label = model.currentSavePlan.map {
            timeline ? "\($0.height) px high (× \($0.width) px)" : "\($0.width) px (× \($0.height) px)"
        } ?? (settings.outputSizeMax ? "max" : "\(settings.outputSize) px")
        VStack(alignment: .leading, spacing: 2) {
            PanelRow("Size") {
                Text(label)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: Theme.space2) {
                Slider(
                    // With max the knob sits at the right end.
                    value: Binding(
                        get: { Double(settings.outputSizeMax ? OutputSize.limit : settings.outputSize) },
                        set: { v in model.updateSettings { $0.outputSize = OutputSize.snapped(Int(v.rounded())) } }),
                    in: Double(OutputSize.steps.first!)...Double(OutputSize.limit), step: 1024
                )
                .controlSize(.small)
                .disabled(settings.outputSizeMax)
                .help(timeline
                      ? "Height of the saved timeline (limited so neither side exceeds 16384 px)"
                      : "Width of the saved print (limited so neither side exceeds 16384 px)")
                Toggle("max", isOn: model.setting(\.outputSizeMax))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Largest size within 16384 px on either side")
            }
        }
    }
}

private struct FormatPicker: View {
    @Binding var selection: ImageFormat
    let help: String

    var body: some View {
        Picker("Format", selection: $selection) {
            ForEach(ImageFormat.allCases, id: \.self) { format in
                Text(format.label).tag(format)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(help)
    }
}

/// The three file-name templates with a live preview of the name each gives
/// now (§6).
private struct NamingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.library.settings
        // The sheet template always; the rest under More (owner, 2026-11-03).
        PanelSection(title: "Naming scheme", expandedKey: "naming") {
            TemplateField(
                title: "Sheet", key: \.sheetNameTemplate, presets: FileNaming.sheetTemplatePresets,
                isThumb: false, fileExtension: settings.outputFormat.fileExtension)
        } more: {
            TemplateField(
                title: "Single thumb", key: \.singleThumbNameTemplate,
                presets: FileNaming.singleThumbTemplatePresets, isThumb: true,
                fileExtension: settings.thumbFormat.fileExtension)
            TemplateField(
                title: "Each thumb", key: \.individualThumbNameTemplate,
                presets: FileNaming.individualThumbTemplatePresets, isThumb: true,
                fileExtension: settings.thumbFormat.fileExtension)
            TokenLegend()
        }
    }
}

/// Gives back the keyboard focus a text field takes on its own. AppKit
/// makes the first text field of a window the first responder when the
/// window opens (and SwiftUI may again when the panel reappears), and the
/// field editor then takes the single-key shortcuts (G, M, 1, 3). Focus
/// stays only when a click or Tab brought it.
private struct FocusOnlyWhenClicked: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onChange(of: focused.wrappedValue) { _, isFocused in
            guard isFocused, !Self.isFocusGesture(NSApp.currentEvent) else { return }
            focused.wrappedValue = false
            // Should SwiftUI not hand the resignation to AppKit (the focus
            // came from AppKit), end the field editor's turn directly.
            Task { @MainActor in
                guard !focused.wrappedValue, let window = NSApp.keyWindow, window.firstResponder is NSText
                else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    /// A click, or Tab moving through the key views.
    static func isFocusGesture(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown: return true
        case .keyDown: return event.keyCode == 48
        default: return false
        }
    }
}

/// The tokens a template may hold, under the fields.
private struct TokenLegend: View {
    static let tokens: [(token: String, meaning: String)] = [
        ("[MN]", "movie name"),
        ("[ME]", "extension"),
        ("[SN]", "sheet name ([MPN] also works)"),
        ("[FN]", "frame number (6 digits)"),
        ("[TC]", "timecode HH_MM_SS_FF"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.space2, verticalSpacing: 1) {
            ForEach(Self.tokens, id: \.token) { item in
                GridRow {
                    Text(item.token)
                    Text(item.meaning)
                }
            }
        }
        .font(Theme.panelCaption)
        .foregroundStyle(Theme.textMuted)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One template: a menu of presets with Custom… at the bottom (owner,
/// 2026-11-03). A stored template that matches a preset shows it; any other
/// shows Custom… and the text field. Choosing Custom… only shows the field,
/// so the stored template changes only when a preset is chosen or the field
/// is edited.
private struct TemplateField: View {
    @Environment(AppModel.self) private var model
    let title: String
    let key: WritableKeyPath<FrameSheetCore.Settings, String>
    let presets: [String]
    /// Thumb templates show a frame and warn without a frame token.
    let isThumb: Bool
    let fileExtension: String
    @FocusState private var focused: Bool
    /// Custom… chosen for a template that matches a preset.
    @State private var customChosen = false

    static let tokensHelp = "[MN] movie name, [ME] extension, [SN] sheet name, [FN] frame number, [TC] timecode"
    /// The menu tag of Custom…; no template holds a NUL.
    static let customTag = "\u{0}custom"

    var body: some View {
        let template = model.library.settings[keyPath: key]
        let isCustom = customChosen || !presets.contains(template)
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(title) {
                Picker(title, selection: Binding(
                    get: { isCustom ? Self.customTag : template },
                    set: { choice in
                        if choice == Self.customTag {
                            customChosen = true
                        } else {
                            customChosen = false
                            if choice != template { model.updateSettings { $0[keyPath: key] = choice } }
                        }
                    })) {
                    ForEach(presets, id: \.self) { preset in
                        Text(preset).tag(preset)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }
                .labelsHidden()
                .fixedSize()
                .help("\(title) file name")
            }
            if isCustom {
                TextField(title, text: model.setting(key))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodySm)
                    .focused($focused)
                    .onChange(of: focused) { _, isFocused in model.isEditingText = isFocused }
                    .modifier(FocusOnlyWhenClicked(focused: $focused))
                    .help(Self.tokensHelp)
            }
            let preview = previewName(template)
            Text(preview)
                .font(Theme.panelCaption)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Preview: \(preview)")
            if isThumb && FileNaming.templateLacksFrameToken(template) {
                Label("Without [FN] or [TC] every thumb gets the same name", systemImage: "exclamationmark.triangle")
                    .font(Theme.panelCaption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    /// The name for the current movie and sheet (and its first visible
    /// thumb), or for an example movie when none is open.
    private func previewName(_ template: String) -> String {
        let file = model.currentFile
        let sheet = model.currentSheet
        let frame = isThumb ? (sheet?.visibleThumbs.first?.frameNumber ?? 0) : nil
        let name = PrintOutput.baseName(
            template: template, movieFileName: file?.name ?? "movie.mp4", sheetName: sheet?.name ?? "Sheet-1",
            frameNumber: frame, fps: (file?.fps ?? 0) > 0 ? file!.fps : 25)
        return "\(name).\(fileExtension)"
    }
}

/// Timeline view (§6): the stats line, minutes per row (per sheet), natural
/// flow (shot sheets), and the shot detection threshold with Add new sheet,
/// which rebuilds the scenes from the stored scan.
private struct TimelineSection: View {
    @Environment(AppModel.self) private var model
    let sheet: Sheet
    @State private var isDragging = false

    var body: some View {
        let file = model.currentFile
        let shots = model.timelineScenes(of: sheet).count
        let frameCount = file?.frameCount ?? 0
        let fps = file?.fps ?? 25
        let stats = TimelineLayout.stats(shots: shots, frameCount: frameCount, fps: fps)
        let line = TimelineLayout.statsLine(shots: shots, frameCount: frameCount, fps: fps)
        let scanned = file.map { model.scanCacheState($0.id) == .complete } ?? false
        PanelSection(title: "Timeline") {
            HStack(spacing: 0) {
                TextStat(value: "\(shots)", label: shots == 1 ? "shot" : "shots")
                TextStat(value: "~\(stats.minutes)", label: stats.minutes == 1 ? "minute" : "minutes")
                TextStat(value: "\(stats.cutsPerMinute)", label: "cut/min")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
            .help(line)
            .padding(.bottom, Theme.space1)
            LabeledSlider(
                title: "Minutes per row",
                value: Binding(
                    get: { sheet.secondsPerRow },
                    set: { model.setSecondsPerRowLive($0.rounded(), editing: isDragging) }),
                range: TimelineLayout.secondsPerRowRange,
                help: "Movie time per row of this sheet",
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { model.endSecondsPerRowDrag() }
                },
                format: { Self.secondsLabel($0) })
            SwitchRow(
                title: "Natural flow", isOn: model.setting(\.timelineNaturalFlow),
                help: "Shot sheets: wrap scenes by width instead of by time")
                .disabled(sheet.type != .shot)
            LabeledSlider(
                title: "Shot threshold", value: model.setting(\.shotDetectionThreshold),
                range: Defaults.shotDetectionThresholdRange, step: 0.5,
                help: "Lower finds more shots", format: { String(format: "%.1f", $0) })
            HStack {
                Spacer(minLength: 0)
                Button("Chart") { model.toggleDetectionChart() }
                    .controlSize(.small)
                    .disabled(file.map { model.scanCacheState($0.id) == .none } ?? true)
                    .help("Detection chart of the stored scan (F)")
                Button("Add new sheet") { model.addShotSheetFromCache() }
                    .controlSize(.small)
                    .disabled(!scanned || model.isScanning)
                    .help(scanned
                          ? "New shot sheet at this threshold, from the stored scan"
                          : "Scan the movie first (Add shot-detection sheet)")
            }
        }
    }

    /// "120 s (2 min)".
    static func secondsLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        guard s >= 60 else { return "\(s) s" }
        let minutes = Double(s) / 60
        let text = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
        return "\(s) s (\(text) min)"
    }
}

/// A large value over a small muted label, one of equal columns.
private struct TextStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(Theme.statValue)
                .foregroundStyle(Theme.text)
            Text(label)
                .font(Theme.panelCaption)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Styling rows of the timeline view (§6): scene width ratio (print width
/// = height × multiplier) and the minimum scene width, set in seconds and
/// stored as frames of the current movie.
private struct TimelineStylingRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fps = model.currentFile?.fps ?? 25
        LabeledSlider(
            title: "Scene width ratio", value: model.setting(\.timelineSceneWidthRatio), range: 0...100,
            help: "Width of the timeline relative to its height",
            format: { String(format: "× %.2f", TimelineLayout.widthMultiplier(sceneWidthRatio: $0)) })
        LabeledSlider(
            title: "Min scene width",
            value: Binding(
                get: { TimelineLayout.minSceneSeconds(frames: model.library.settings.timelineMinSceneLength, fps: fps) },
                set: { v in
                    model.updateSettings { $0.timelineMinSceneLength = TimelineLayout.minSceneFrames(seconds: v, fps: fps) }
                }),
            range: TimelineLayout.minSceneSecondsRange, unit: " s",
            help: "Short scenes are drawn at least this long")
    }
}

/// Face detection (§6): the thresholds a face scan stores faces with. On a
/// faces sheet, Apply rescans the sheet's frames with them and replaces its
/// thumbs.
private struct FaceDetectionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelSection(title: "Face detection") {
            LabeledSlider(
                title: "Confidence", value: model.setting(\.faceConfidenceThreshold), range: 0...100,
                help: "Faces detected with a lower confidence are ignored")
            LabeledSlider(
                title: "Size", value: model.setting(\.faceSizeThreshold), range: 0...100, unit: " %",
                help: "Faces smaller than this share of the frame height are ignored")
            HStack {
                Text(model.isFacesSheetShown ? "Apply rescans this faces sheet" : "Takes effect on the next scan")
                    .font(Theme.panelCaption)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                let canApply = model.canApplyFaceThresholds
                let applied = model.isFacesSheetShown && !model.isScanning && !canApply
                Button("Apply") { model.applyFaceThresholds() }
                    .controlSize(.small)
                    .disabled(!canApply)
                    .help(applied ? "These thresholds are already applied" : "Rescan this faces sheet with these thresholds")
            }
        }
    }
}

/// Experimental (§6): the shot detection method. Automatic IN/OUT moved
/// to the Grid section (owner, 2026-11-03).
private struct ExperimentalSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelSection(title: "Experimental", expandedKey: "experimental") {
            EmptyView()
        } more: {
            PanelRow("Shot detection") {
                Picker("Shot detection", selection: model.setting(\.shotDetectionMethod)) {
                    ForEach(ShotDetectionMethod.allCases, id: \.self) { method in
                        Text(method.label).tag(method)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Method of the next scan (a new method scans again)")
            }
        }
    }
}
