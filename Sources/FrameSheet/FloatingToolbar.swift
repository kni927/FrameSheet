import FrameSheetCore
import SwiftUI

/// The bar floating over the main area (§4), the parts that work on
/// interval sheets: back to parent, add interval sheet, duplicate, zoom,
/// show hidden thumbs, cycle frame info, optimise grid layout.
struct FloatingToolbar: View {
    @Environment(AppModel.self) private var model
    let sheet: Sheet

    var body: some View {
        let settings = model.library.settings
        HStack(spacing: Theme.space1) {
            ToolButton("Back to parent: return to the sheet this one was expanded from", systemImage: "arrow.uturn.backward") { model.backToParent() }
                .disabled(sheet.parentSheetId == nil)
            Menu {
                ForEach(2...6, id: \.self) { n in
                    Button("\(n) × \(n)") { model.addIntervalSheet(columns: n, rows: n) }
                }
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add interval sheet: a new sheet of 2×2 … 6×6 thumbs spread evenly over the movie")
            ToolButton("Duplicate sheet: copy this sheet as a new MoviePrint-N", systemImage: "plus.square.on.square") {
                if let ref = model.currentRef { model.duplicateSheet(ref) }
            }
            Separator()
            ToolButton("Zoom out (⌘−)", systemImage: "minus.magnifyingglass") { model.zoom(in: false) }
                .disabled(model.zoom <= GridGeometry.zoomSteps.first!)
            Button {
                model.zoomToFit()
            } label: {
                Text(model.zoom == 1 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%")
                    .font(Theme.mono(12, medium: true))
                    .frame(minWidth: 40, minHeight: 28)
            }
            .buttonStyle(.plain)
            .help("Fit the sheet to the window (⌘0)")
            ToolButton("Zoom in (⌘=)", systemImage: "plus.magnifyingglass") { model.zoom(in: true) }
                .disabled(model.zoom >= GridGeometry.zoomSteps.last!)
            Separator()
            ToolButton(
                settings.showHiddenThumbs ? "Hide hidden thumbs" : "Show hidden thumbs",
                systemImage: settings.showHiddenThumbs ? "eye" : "eye.slash",
                active: settings.showHiddenThumbs
            ) {
                model.updateSettings { $0.showHiddenThumbs.toggle() }
            }
            ToolButton(
                "Frame info on thumbs: \(frameInfoName(settings.frameInfo)) — click to cycle frames → timecode → none",
                systemImage: "number.square", active: settings.frameInfo != .hidden
            ) {
                model.cycleFrameInfo()
            }
            ToolButton("Optimise grid layout: columns = √(number of thumbs), rounded up", systemImage: "square.grid.3x3") { model.optimiseGrid() }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, Theme.space1)
        .background(Theme.crust, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func frameInfoName(_ mode: FrameInfo) -> String {
        switch mode {
        case .frames: "frames"
        case .timecode: "timecode"
        case .hidden: "hidden"
        }
    }
}

private struct ToolButton: View {
    let title: String
    let systemImage: String
    var active = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(_ title: String, systemImage: String, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .foregroundStyle(active ? Theme.accentInk : (isEnabled ? Theme.text : Theme.textMuted.opacity(0.5)))
                .background(
                    hovering && isEnabled ? Theme.surface : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, Theme.space1)
    }
}
