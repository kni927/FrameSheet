import FrameSheetCore
import SwiftUI

/// The sheet tools in the window toolbar next to the title (§4's floating
/// toolbar, moved there by the owner, 2026-11-03), the parts that work on
/// interval sheets: back to parent, add interval sheet, duplicate, zoom (with
/// Fit height and Fit width when they would change the fit), show hidden
/// thumbs, cycle frame info, optimize grid layout, then the right panel
/// toggle. Disabled while no sheet is shown (not the toggle). Each group is
/// one `ToolbarIconGroup` in a single toolbar item, so its icons touch; the
/// items have no glass background.
struct SheetToolbar: ToolbarContent {
    let model: AppModel
    let sheet: Sheet?

    var body: some ToolbarContent {
        let settings = model.library.settings
        let noSheet = sheet == nil
        let geometry = noSheet ? nil : model.currentGridGeometry
        ToolbarItem(placement: .navigation) {
            ToolbarIconGroup {
                Button {
                    model.backToParent()
                } label: {
                    Label("Back to parent", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .help("Back to parent sheet")
                .disabled(sheet?.parentSheetId == nil)
                Menu {
                    ForEach(2...6, id: \.self) { n in
                        Button("\(n) × \(n)") { model.addIntervalSheet(columns: n, rows: n) }
                    }
                } label: {
                    Label("Add interval sheet", systemImage: "rectangle.stack.badge.plus")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .help("Add interval sheet")
                .disabled(noSheet)
                Button {
                    if let ref = model.currentRef { model.duplicateSheet(ref) }
                } label: {
                    Label("Duplicate sheet", systemImage: "plus.square.on.square")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .help("Duplicate sheet")
                .disabled(noSheet)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            ToolbarIconGroup {
                Button {
                    model.zoom(in: false)
                } label: {
                    Label("Zoom out", systemImage: "minus.magnifyingglass")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .help("Zoom out (⌘−)")
                .disabled(noSheet || model.zoom <= GridGeometry.zoomSteps.first!)
                // Only when the print leaves space in that direction.
                if geometry?.hasSpaceAboveAndBelow == true {
                    Button {
                        model.zoomToFitHeight()
                    } label: {
                        Label("Fit height", systemImage: "arrow.up.and.down")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .help("Fit height")
                }
                if geometry?.hasSpaceAtSides == true {
                    Button {
                        model.zoomToFitWidth()
                    } label: {
                        Label("Fit width", systemImage: "arrow.left.and.right")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .help("Fit width")
                }
                Button {
                    model.zoomToFit()
                } label: {
                    Label("Fit", systemImage: "square.arrowtriangle.4.outward")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .help("Fit (⌘0) · \(Int((model.zoom * 100).rounded()))%")
                .disabled(noSheet)
                Button {
                    model.zoom(in: true)
                } label: {
                    Label("Zoom in", systemImage: "plus.magnifyingglass")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .help("Zoom in (⌘=)")
                .disabled(noSheet || model.zoom >= GridGeometry.zoomSteps.last!)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            // In the main window toolbar, not the inspector's, so the panel
            // toggle stays when the panel is hidden; a small gap sets it apart.
            HStack(spacing: Theme.space3) {
                ToolbarIconGroup {
                    // A button drawn as selected while on, so it shares the icon style.
                    Button {
                        model.updateSettings { $0.showHiddenThumbs.toggle() }
                    } label: {
                        Label("Show hidden thumbs", systemImage: settings.showHiddenThumbs ? "eye" : "eye.slash")
                    }
                    .buttonStyle(ToolbarIconStyle(selected: settings.showHiddenThumbs, grouped: true))
                    .accessibilityAddTraits(settings.showHiddenThumbs ? .isSelected : [])
                    .help("Show hidden thumbs")
                    .disabled(noSheet)
                    Button {
                        model.cycleFrameInfo()
                    } label: {
                        Label(
                            "Frame info",
                            systemImage: settings.frameInfo == .hidden ? "123.rectangle" : "123.rectangle.fill")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .help("Frame info: \(frameInfoName(settings.frameInfo)) (click cycles)")
                    .disabled(noSheet)
                    Button {
                        model.optimiseGrid()
                    } label: {
                        Label("Optimize grid", systemImage: "square.grid.3x3")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .help("Optimize grid layout")
                    .disabled(noSheet)
                }
                Button {
                    model.showSettings.toggle()
                } label: {
                    Label(model.showSettings ? "Hide panel" : "Show panel", systemImage: "sidebar.right")
                }
                .buttonStyle(ToolbarIconStyle(selected: model.showSettings))
                .accessibilityAddTraits(model.showSettings ? .isSelected : [])
                .help(model.showSettings ? "Hide panel (3)" : "Show panel (3)")
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func frameInfoName(_ mode: FrameInfo) -> String {
        switch mode {
        case .frames: "frames"
        case .timecode: "timecode"
        case .hidden: "none"
        }
    }
}
