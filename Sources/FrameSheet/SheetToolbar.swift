import FrameSheetCore
import SwiftUI

/// The window toolbar after the app name (§4's floating toolbar, moved there
/// by the owner, 2026-11-03), customizable (owner, 2026-11-05): one item per
/// control, so the overflow menu and Customize Toolbar… list each of them. By
/// default: Add movies, the sheet adders, Undo and Redo, the zoom, Grid /
/// Timeline, the player view, Save sheet and the panel toggle; the rest is in
/// the customization palette. Every action is in a menu too (`AppCommands`).
/// Disabled while no sheet is shown (not the toggles); Fit height and Fit
/// width are disabled, not hidden, when they would not change the fit. Each
/// control has its own tooltip (`toolbarHelp`).
struct SheetToolbar: CustomizableToolbarContent {
    let model: AppModel
    let sheet: Sheet?

    var body: some CustomizableToolbarContent {
        let settings = model.library.settings
        let noSheet = sheet == nil
        let geometry = noSheet ? nil : model.currentFit
        let timeline = sheet.map(model.isTimeline) ?? false
        item("addMovies", "Add movies", "plus", help: "Add movies (A)") { model.presentOpenPanel() }
        item("backToParent", "Back to parent", "arrow.turn.left.up", shown: false, help: "Back to parent sheet (⇧⌘P)",
             disabled: sheet?.parentSheetId == nil) { model.backToParent() }
        ToolbarItem(id: "addInterval", placement: Self.placement) {
            Menu {
                ForEach(2...6, id: \.self) { n in
                    Button("\(n) × \(n)") { model.addIntervalSheet(columns: n, rows: n) }
                }
            } label: {
                Label("Add interval sheet", systemImage: "rectangle.stack.badge.plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ToolbarIconStyle())
            .toolbarHelp("Add interval sheet")
            .disabled(noSheet)
        }
        .sharedBackgroundVisibility(.hidden)
        item("addShots", "Add shot-detection sheet", "barcode.viewfinder", help: shotSheetHelp,
             disabled: noSheet || model.isScanning) { model.addShotDetectionSheet() }
        // Add faces sheet (§4): a click opens the scopes (owner, 2026-11-05).
        ToolbarItem(id: "addFaces", placement: Self.placement) {
            Menu {
                ForEach(FaceScanScope.allCases, id: \.self) { scope in
                    if scope == .thumbs { Divider() }
                    Button(scope.label) { model.addFacesSheet(scope) }
                        .help(scope.help)
                }
            } label: {
                Label("Add faces sheet", systemImage: "person.crop.rectangle.stack")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ToolbarIconStyle())
            .toolbarHelp("Add faces sheet")
            .disabled(noSheet || model.isScanning || sheet?.type == .faces)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "sort", placement: Self.placement, showsByDefault: false) {
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
            .buttonStyle(ToolbarIconStyle())
            .toolbarHelp("Sort thumbs")
            .disabled(noSheet || sheet?.type == .shot || model.isStreamingSheetShown)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "filter", placement: Self.placement, showsByDefault: false) {
            FaceFilterButton(model: model, sheet: sheet)
        }
        .sharedBackgroundVisibility(.hidden)
        item("duplicate", "Duplicate sheet", "plus.square.on.square", shown: false, help: "Duplicate sheet (⌘D)",
             disabled: noSheet) {
            if let ref = model.currentRef { model.duplicateSheet(ref) }
        }
        // The Edit menu's Undo and Redo, text field typing included.
        item("undo", "Undo", "arrow.uturn.backward", help: "Undo (⌘Z)", disabled: !model.canPerformUndo) {
            model.performUndo()
        }
        item("redo", "Redo", "arrow.uturn.forward", help: "Redo (⇧⌘Z)", disabled: !model.canPerformRedo) {
            model.performRedo()
        }
        item("zoomOut", "Zoom out", "minus.magnifyingglass", help: "Zoom out (⌘−)",
             disabled: noSheet || model.zoom <= GridGeometry.zoomSteps.first!) { model.zoom(in: false) }
        item("fitHeight", "Fit height", "arrow.up.and.down", shown: false, help: "Fit height (⌃⌘0)",
             disabled: geometry?.hasSpaceAboveAndBelow != true) { model.zoomToFitHeight() }
        item("fitWidth", "Fit width", "arrow.left.and.right", shown: false, help: "Fit width (⌥⌘0)",
             disabled: geometry?.hasSpaceAtSides != true) { model.zoomToFitWidth() }
        item("fit", "Fit", "square.arrowtriangle.4.outward",
             help: "Fit (⌘0) · \(Int((model.zoom * 100).rounded()))%", disabled: noSheet) { model.zoomToFit() }
        item("zoomIn", "Zoom in", "plus.magnifyingglass", help: "Zoom in (⌘=)",
             disabled: noSheet || model.zoom >= GridGeometry.zoomSteps.last!) { model.zoom(in: true) }
        item("showHidden", "Show hidden thumbs", settings.showHiddenThumbs ? "eye" : "eye.slash", shown: false,
             selected: settings.showHiddenThumbs, help: "Show hidden thumbs (⇧⌘H)", disabled: noSheet) {
            model.updateSettings { $0.showHiddenThumbs.toggle() }
        }
        item("showHeader", "Show header", "rectangle.topthird.inset.filled", shown: false,
             selected: settings.showHeader, help: "Show header (⇧⌘E)", disabled: noSheet || timeline) {
            model.updateSettings { $0.showHeader.toggle() }
        }
        item("frameInfo", "Thumb label", settings.frameInfo == .hidden ? "123.rectangle" : "123.rectangle.fill",
             shown: false, help: "Thumb label: \(frameInfoName(settings.frameInfo)) (click cycles)",
             disabled: noSheet) { model.cycleFrameInfo() }
        item("faceRectangles", "Face rectangles", "person.crop.square", shown: false,
             selected: settings.showFaceRectangles,
             help: settings.showFaceRectangles ? "Hide face rectangles (⌥⌘R)" : "Show face rectangles (⌥⌘R)",
             disabled: sheet?.type != .faces) { model.updateSettings { $0.showFaceRectangles.toggle() } }
        item("view", timeline ? "Grid view" : "Timeline view", timeline ? "square.grid.2x2" : "barcode",
             help: timeline ? "Grid view (G)" : "Timeline view (G)", disabled: noSheet || sheet?.type == .faces) {
            if let ref = model.currentRef { model.toggleView(ref) }
        }
        item("player", model.player.isShown ? "Hide player view" : "Show player view", "play.rectangle",
             selected: model.player.isShown,
             help: model.player.isShown ? "Hide player view (2)" : "Show player view (2)",
             disabled: noSheet && !model.player.isShown) { model.togglePlayerView() }
        item("meanColors", "Mean colors only", settings.timelineShowImages ? "photo" : "paintpalette", shown: false,
             selected: !settings.timelineShowImages,
             help: settings.timelineShowImages ? "Show mean colors only (⌥⌘I)" : "Show images (⌥⌘I)",
             disabled: noSheet || !timeline) { model.updateSettings { $0.timelineShowImages.toggle() } }
        item("optimizeGrid", "Optimize grid", "square.grid.3x3", shown: false, help: "Optimize grid layout (⌥⌘O)",
             disabled: noSheet || timeline) { model.optimizeGrid() }
        // Cut and merge on the selected scene of a shot sheet (§7).
        item("cut", "Cut scene", "scissors", shown: false,
             help: model.player.isShown ? "Cut scene at the player's frame (⌘K)" : "Cut scene at its thumb (⌘K)",
             disabled: (model.player.isShown ? sheet?.type != .shot : model.selectedScene == nil)
                || model.isStreamingSheetShown) { model.cutSelectedScene() }
        item("mergePrevious", "Merge with previous", "square.filled.and.line.vertical.and.square", shown: false,
             help: "Merge with previous scene (⌘[)",
             disabled: !model.canMergeSelectedScene(.previous) || model.isStreamingSheetShown) {
            model.mergeSelectedScene(.previous)
        }
        item("mergeNext", "Merge with next", "square.and.line.vertical.and.square.filled", shown: false,
             help: "Merge with next scene (⌘])",
             disabled: !model.canMergeSelectedScene(.next) || model.isStreamingSheetShown) {
            model.mergeSelectedScene(.next)
        }
        // Save All and the output location are in the File menu.
        item("save", "Save sheet", "square.and.arrow.down", help: "Save sheet (M)",
             disabled: noSheet || model.isSaving) { model.saveSheet() }
        ToolbarSpacer(.flexible, placement: Self.placement)
        item("panel", model.showSettings ? "Hide panel" : "Show panel", "sidebar.right",
             selected: model.showSettings, help: model.showSettings ? "Hide panel (3)" : "Show panel (3)") {
            model.showSettings.toggle()
        }
    }

    private static let placement = ToolbarItemPlacement.automatic

    /// One button item, shown by default unless `shown` is false.
    private func item(
        _ id: String, _ title: String, _ systemImage: String, shown: Bool = true, selected: Bool = false,
        help: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some CustomizableToolbarContent {
        ToolbarItem(id: id, placement: Self.placement, showsByDefault: shown) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(ToolbarIconStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .toolbarHelp(help)
            .disabled(disabled)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Add shot-detection sheet: what it will do for the current movie.
    private var shotSheetHelp: String {
        guard let id = model.library.currentFileId else { return "Add shot-detection sheet (⇧⌘D)" }
        switch model.scanCacheState(id) {
        case .complete: return "Add shot-detection sheet from the stored scan (⇧⌘D)"
        case .partial: return "Resume shot detection (⇧⌘D)"
        case .none: return "Add shot-detection sheet: scans the movie (⇧⌘D)"
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
        .buttonStyle(ToolbarIconStyle(selected: active))
        .accessibilityAddTraits(active ? .isSelected : [])
        .toolbarHelp("Filter faces (⌥⌘F)")
        .disabled(sheet?.type != .faces)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            FaceFilterPanel(model: model)
        }
    }
}

struct FaceFilterPanel: View {
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
