import FrameSheetCore
import SwiftUI

/// The sheet tools in the window toolbar next to the title (§4's floating
/// toolbar, moved there by the owner, 2026-11-03): back to parent, add
/// interval sheet, add shot-detection sheet, duplicate, undo and redo, zoom
/// (with Fit height and Fit width when they would change the fit), show
/// hidden thumbs, show header, cycle the thumb label, grid/timeline, player
/// view, toggle images (timeline), optimize grid layout, Save Sheet with its menu, then
/// the right panel toggle. Disabled while no sheet is shown (not the toggle). Each group is
/// one `ToolbarIconGroup` in a single toolbar item, so its icons touch; the
/// items have no glass background, and each control has its own tooltip
/// (`toolbarHelp`).
struct SheetToolbar: ToolbarContent {
    let model: AppModel
    let sheet: Sheet?

    var body: some ToolbarContent {
        let settings = model.library.settings
        let noSheet = sheet == nil
        let geometry = noSheet ? nil : model.currentFit
        let timeline = sheet.map(model.isTimeline) ?? false
        ToolbarItem(placement: .navigation) {
            ToolbarIconGroup {
                Button {
                    model.backToParent()
                } label: {
                    Label("Back to parent", systemImage: "arrow.turn.left.up")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Back to parent sheet")
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
                .toolbarHelp("Add interval sheet")
                .disabled(noSheet)
                Button {
                    model.addShotDetectionSheet()
                } label: {
                    Label("Add shot-detection sheet", systemImage: "barcode.viewfinder")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp(shotSheetHelp)
                .disabled(noSheet || model.isScanning)
                // Add faces sheet (§4): a click scans with the default
                // scope; the menu (press and hold) offers all three.
                Menu {
                    ForEach(FaceScanScope.allCases, id: \.self) { scope in
                        if scope == .thumbs { Divider() }
                        Button(scope.label) { model.addFacesSheet(scope) }
                            .help(scope.help)
                    }
                } label: {
                    Label("Add faces sheet", systemImage: "person.crop.rectangle.stack")
                } primaryAction: {
                    model.addFacesSheet(model.defaultFaceScanScope)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Add faces sheet: \(model.defaultFaceScanScope.label.lowercased()) (hold for more)")
                .disabled(noSheet || model.isScanning || sheet?.type == .faces)
                Menu {
                    ForEach(ThumbSort.allCases, id: \.self) { sort in
                        Button(sort.label) { model.sortSheet(sort) }
                            .disabled(sort.needsFaces && sheet?.type != .faces)
                        if sort == .frameNumber { Divider() }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Sort thumbs")
                .disabled(noSheet || sheet?.type == .shot || model.isStreamingSheetShown)
                FaceFilterButton(model: model, sheet: sheet)
                Button {
                    if let ref = model.currentRef { model.duplicateSheet(ref) }
                } label: {
                    Label("Duplicate sheet", systemImage: "plus.square.on.square")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Duplicate sheet")
                .disabled(noSheet)
                // The Edit menu's Undo and Redo, text field typing included.
                Button {
                    model.performUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Undo (⌘Z)")
                .disabled(!model.canPerformUndo)
                Button {
                    model.performRedo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Redo (⇧⌘Z)")
                .disabled(!model.canPerformRedo)
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
                .toolbarHelp("Zoom out (⌘−)")
                .disabled(noSheet || model.zoom <= GridGeometry.zoomSteps.first!)
                // Only when the print leaves space in that direction.
                if geometry?.hasSpaceAboveAndBelow == true {
                    Button {
                        model.zoomToFitHeight()
                    } label: {
                        Label("Fit height", systemImage: "arrow.up.and.down")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Fit height")
                }
                if geometry?.hasSpaceAtSides == true {
                    Button {
                        model.zoomToFitWidth()
                    } label: {
                        Label("Fit width", systemImage: "arrow.left.and.right")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Fit width")
                }
                Button {
                    model.zoomToFit()
                } label: {
                    Label("Fit", systemImage: "square.arrowtriangle.4.outward")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Fit (⌘0) · \(Int((model.zoom * 100).rounded()))%")
                .disabled(noSheet)
                Button {
                    model.zoom(in: true)
                } label: {
                    Label("Zoom in", systemImage: "plus.magnifyingglass")
                }
                .buttonStyle(ToolbarIconStyle(grouped: true))
                .toolbarHelp("Zoom in (⌘=)")
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
                    .toolbarHelp("Show hidden thumbs")
                    .disabled(noSheet)
                    Button {
                        model.updateSettings { $0.showHeader.toggle() }
                    } label: {
                        Label("Show header", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .buttonStyle(ToolbarIconStyle(selected: settings.showHeader, grouped: true))
                    .accessibilityAddTraits(settings.showHeader ? .isSelected : [])
                    .toolbarHelp("Show header")
                    .disabled(noSheet || timeline)
                    Button {
                        model.cycleFrameInfo()
                    } label: {
                        Label(
                            "Frame info",
                            systemImage: settings.frameInfo == .hidden ? "123.rectangle" : "123.rectangle.fill")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Thumb label: \(frameInfoName(settings.frameInfo)) (click cycles)")
                    .disabled(noSheet)
                    Button {
                        model.updateSettings { $0.showFaceRectangles.toggle() }
                    } label: {
                        Label("Face rectangles", systemImage: "person.crop.square")
                    }
                    .buttonStyle(ToolbarIconStyle(selected: settings.showFaceRectangles, grouped: true))
                    .accessibilityAddTraits(settings.showFaceRectangles ? .isSelected : [])
                    .toolbarHelp(settings.showFaceRectangles ? "Hide face rectangles" : "Show face rectangles")
                    .disabled(sheet?.type != .faces)
                    Button {
                        if let ref = model.currentRef { model.toggleView(ref) }
                    } label: {
                        Label(timeline ? "Grid view" : "Timeline view", systemImage: timeline ? "square.grid.2x2" : "barcode")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp(timeline ? "Grid view (G)" : "Timeline view (G)")
                    .disabled(noSheet || sheet?.type == .faces)
                    Button {
                        model.togglePlayerView()
                    } label: {
                        Label(model.player.isShown ? "Hide player view" : "Show player view", systemImage: "play.rectangle")
                    }
                    .buttonStyle(ToolbarIconStyle(selected: model.player.isShown, grouped: true))
                    .accessibilityAddTraits(model.player.isShown ? .isSelected : [])
                    .toolbarHelp(model.player.isShown ? "Hide player view (2)" : "Show player view (2)")
                    .disabled(noSheet && !model.player.isShown)
                    Button {
                        model.updateSettings { $0.timelineShowImages.toggle() }
                    } label: {
                        Label("Toggle images", systemImage: settings.timelineShowImages ? "photo" : "paintpalette")
                    }
                    .buttonStyle(ToolbarIconStyle(selected: !settings.timelineShowImages, grouped: true))
                    .accessibilityAddTraits(!settings.timelineShowImages ? .isSelected : [])
                    .toolbarHelp(settings.timelineShowImages ? "Show mean colors only" : "Show images")
                    .disabled(noSheet || !timeline)
                    Button {
                        model.optimizeGrid()
                    } label: {
                        Label("Optimize grid", systemImage: "square.grid.3x3")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Optimize grid layout")
                    .disabled(noSheet || timeline)
                }
                // Cut and merge on the selected scene of a shot sheet (§7),
                // in grid and timeline view; one undo step each.
                ToolbarIconGroup {
                    let scene = model.selectedScene
                    Button {
                        model.cutSelectedScene()
                    } label: {
                        Label("Cut scene", systemImage: "scissors")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp(model.player.isShown ? "Cut scene at the player's frame" : "Cut scene at its thumb")
                    .disabled(
                        (model.player.isShown ? sheet?.type != .shot : scene == nil) || model.isStreamingSheetShown)
                    Button {
                        model.mergeSelectedScene(.previous)
                    } label: {
                        Label("Merge with previous", systemImage: "square.filled.and.line.vertical.and.square")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Merge with previous scene")
                    .disabled(!model.canMergeSelectedScene(.previous) || model.isStreamingSheetShown)
                    Button {
                        model.mergeSelectedScene(.next)
                    } label: {
                        Label("Merge with next", systemImage: "square.and.line.vertical.and.square.filled")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Merge with next scene")
                    .disabled(!model.canMergeSelectedScene(.next) || model.isStreamingSheetShown)
                    Button {
                        model.toggleDetectionChart()
                    } label: {
                        Label("Detection chart", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Detection chart (F)")
                    .disabled(noSheet)
                }
                // Save (decision 23): the download button, and a menu with
                // the output location (Save All comes with T08).
                ToolbarIconGroup {
                    Button {
                        model.saveSheet()
                    } label: {
                        Label("Save sheet", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Save sheet (M)")
                    .disabled(noSheet || model.isSaving)
                    Menu {
                        Button("Open Output Location") { model.openOutputLocation() }
                    } label: {
                        Label("Save options", systemImage: "chevron.down")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("More save options")
                }
                Button {
                    model.showSettings.toggle()
                } label: {
                    Label(model.showSettings ? "Hide panel" : "Show panel", systemImage: "sidebar.right")
                }
                .buttonStyle(ToolbarIconStyle(selected: model.showSettings))
                .accessibilityAddTraits(model.showSettings ? .isSelected : [])
                .toolbarHelp(model.showSettings ? "Hide panel (3)" : "Show panel (3)")
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Add shot-detection sheet: what it will do for the current movie.
    private var shotSheetHelp: String {
        guard let id = model.library.currentFileId else { return "Add shot-detection sheet" }
        switch model.scanCacheState(id) {
        case .complete: return "Add shot-detection sheet (from the stored scan)"
        case .partial: return "Resume shot detection"
        case .none: return "Add shot-detection sheet (scans the movie)"
        }
    }

    private func frameInfoName(_ mode: FrameInfo) -> String {
        switch mode {
        case .frames: "frames"
        case .timecode: "timecode"
        case .hidden: "none"
        }
    }
}

/// Filter (§4, faces sheets): a popover with the face count and face size
/// ranges, each with its switch (MoviePrint `FloatingMenu`'s filter
/// dropdown). Every change is one undo step; a slider applies when it is
/// released.
private struct FaceFilterButton: View {
    let model: AppModel
    let sheet: Sheet?
    @State private var shown = false

    var body: some View {
        let active = sheet?.faceFilter?.isActive == true
        Button {
            shown.toggle()
        } label: {
            Label(
                "Filter",
                systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(ToolbarIconStyle(selected: active, grouped: true))
        .accessibilityAddTraits(active ? .isSelected : [])
        .toolbarHelp("Filter faces")
        .disabled(sheet?.type != .faces)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            FaceFilterPanel(model: model)
        }
    }
}

private struct FaceFilterPanel: View {
    let model: AppModel
    /// Slider positions while dragging; applied on release.
    @State private var sizeLower: Double?
    @State private var sizeUpper: Double?

    var body: some View {
        let filter = model.currentSheet?.faceFilter ?? FaceFilter()
        let maxCount = FaceFilter.faceCountRange.upperBound
        let minSize = min(model.library.settings.faceSizeThreshold, FaceFilter.sizeMaximum - 1)
        VStack(alignment: .leading, spacing: Theme.space2) {
            Toggle("Face count", isOn: Binding(
                get: { filter.faceCount.enabled },
                set: { on in apply { $0.faceCount.enabled = on } }))
                .help("Show frames with this many faces")
            HStack(spacing: Theme.space3) {
                Stepper(
                    "From \(Int(filter.faceCount.lower))",
                    value: Binding(get: { filter.faceCount.lower }, set: { v in apply { $0.faceCount.lower = v } }),
                    in: FaceFilter.faceCountRange.lowerBound...filter.faceCount.upper)
                Stepper(
                    "To \(filter.faceCount.upper >= maxCount ? "max" : "\(Int(filter.faceCount.upper))")",
                    value: Binding(get: { filter.faceCount.upper }, set: { v in apply { $0.faceCount.upper = v } }),
                    in: filter.faceCount.lower...maxCount)
            }
            .monospacedDigit()
            .disabled(!filter.faceCount.enabled)
            Divider()
            Toggle("Face size", isOn: Binding(
                get: { filter.size.enabled },
                set: { on in apply { $0.size.enabled = on } }))
                .help("Show frames with a face of this size (% of the frame height)")
            sizeSlider(
                "From", value: sizeLower ?? filter.size.lower, range: minSize...FaceFilter.sizeMaximum,
                drag: $sizeLower) { v in apply { $0.size.lower = min(v, $0.size.upper) } }
                .disabled(!filter.size.enabled)
            sizeSlider(
                "To", value: sizeUpper ?? filter.size.upper, range: minSize...FaceFilter.sizeMaximum,
                drag: $sizeUpper) { v in apply { $0.size.upper = max(v, $0.size.lower) } }
                .disabled(!filter.size.enabled)
        }
        .controlSize(.small)
        .font(Theme.bodySm)
        .padding(Theme.space3)
        .frame(width: 240)
    }

    private func sizeSlider(
        _ title: String, value: Double, range: ClosedRange<Double>, drag: Binding<Double?>,
        commit: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: Theme.space2) {
            Text(title).frame(width: 36, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: { drag.wrappedValue = $0.rounded() }), in: range, step: 1
            ) { editing in
                guard !editing, let final = drag.wrappedValue else { return }
                drag.wrappedValue = nil
                commit(final)
            }
            Text(value >= FaceFilter.sizeMaximum ? "max" : "\(Int(value))%")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func apply(_ change: (inout FaceFilter) -> Void) {
        var filter = model.currentSheet?.faceFilter ?? FaceFilter()
        change(&filter)
        model.setFaceFilter(filter)
    }
}
