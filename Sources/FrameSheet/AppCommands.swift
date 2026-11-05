import FrameSheetCore
import SwiftUI

/// The menus (owner, 2026-11-05): every toolbar action is in a menu, most
/// with a ⌘ shortcut, and Import Sheet, Clear Movie List, the save options
/// and the detection chart are only here. The single-letter keys of §8 (A,
/// M, F, G, 1, 2, 3) keep working through the key monitor and have ⌘
/// shortcuts here as well: a menu shortcut without ⌘ would also fire while
/// a text field has focus, one with ⌘ does not.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let sheet = model.currentSheet
        let noSheet = sheet == nil
        let timeline = sheet.map(model.isTimeline) ?? false
        let settings = model.library.settings

        CommandGroup(replacing: .newItem) {
            Button("Add Movies…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("Import Sheet…") { model.presentImportPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Save Sheet") { model.saveSheet() }
                .keyboardShortcut("s")
                .disabled(noSheet || model.isSaving)
            Button("Save All Sheets") { model.saveAllSheets() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.library.files.isEmpty || model.isSaving || model.isScanning)
            Button("Open Output Location") { model.openOutputLocation() }
            Divider()
            Button("Clear Movie List…") { model.confirmingClear = true }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.library.files.isEmpty)
        }
        // Library undo (§3), or the typing while a text field is being
        // edited (`AppModel.performUndo`); the toolbar has the same.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canPerformUndo)
            Button("Redo") { model.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canPerformRedo)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate Sheet") {
                if let ref = model.currentRef { model.duplicateSheet(ref) }
            }
            .keyboardShortcut("d")
            .disabled(noSheet)
        }

        CommandMenu("Sheet") {
            Menu("Add Interval Sheet") {
                ForEach(2...6, id: \.self) { n in
                    Button("\(n) × \(n)") { model.addIntervalSheet(columns: n, rows: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .control])
                }
            }
            .disabled(noSheet)
            Button("Add Shot-Detection Sheet") { model.addShotDetectionSheet() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(noSheet || model.isScanning)
            Menu("Add Faces Sheet") {
                ForEach(FaceScanScope.allCases, id: \.self) { scope in
                    if scope == .thumbs { Divider() }
                    if scope == .everyTenth {
                        Button(scope.label) { model.addFacesSheet(scope) }
                            .keyboardShortcut("f", modifiers: [.command, .shift])
                    } else {
                        Button(scope.label) { model.addFacesSheet(scope) }
                    }
                }
            }
            .disabled(noSheet || model.isScanning || sheet?.type == .faces)
            Button("Back to Parent Sheet") { model.backToParent() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(sheet?.parentSheetId == nil)
            Divider()
            Menu("Sort") {
                ForEach(ThumbSort.allCases, id: \.self) { sort in
                    Button(sort.label) { model.sortSheet(sort) }
                        .disabled(sort.needsFaces && sheet?.type != .faces)
                    if sort == .frameNumber { Divider() }
                }
            }
            .disabled(noSheet || sheet?.type == .shot || model.isStreamingSheetShown)
            Button("Filter Faces…") { model.faceFilterShown = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(sheet?.type != .faces)
            Button("Optimize Grid Layout") { model.optimizeGrid() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(noSheet || timeline)
            Divider()
            // Cut and merge on the selected scene of a shot sheet (§7).
            Button("Cut Scene") { model.cutSelectedScene() }
                .keyboardShortcut("k")
                .disabled(
                    (model.player.isShown ? sheet?.type != .shot : model.selectedScene == nil)
                        || model.isStreamingSheetShown)
            Button("Merge with Previous Scene") { model.mergeSelectedScene(.previous) }
                .keyboardShortcut("[")
                .disabled(!model.canMergeSelectedScene(.previous) || model.isStreamingSheetShown)
            Button("Merge with Next Scene") { model.mergeSelectedScene(.next) }
                .keyboardShortcut("]")
                .disabled(!model.canMergeSelectedScene(.next) || model.isStreamingSheetShown)
            Divider()
            Button("Face Detection…") { model.faceDetectionShown = true }
                .keyboardShortcut("d", modifiers: [.command, .option])
            // Also key F (the key monitor).
            Button(model.detectionChart == nil ? "Show Detection Chart" : "Hide Detection Chart") {
                model.toggleDetectionChart()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.currentFile == nil)
        }

        // View menu; Enter Full Screen (🌐F on macOS 27) comes with the
        // window, Show Toolbar and Customize Toolbar… with `ToolbarCommands`.
        CommandGroup(before: .toolbar) {
            let fit = noSheet ? nil : model.currentFit
            Button("Fit") { model.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(noSheet)
            Button("Fit Height") { model.zoomToFitHeight() }
                .keyboardShortcut("0", modifiers: [.command, .control])
                .disabled(fit?.hasSpaceAboveAndBelow != true)
            Button("Fit Width") { model.zoomToFitWidth() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(fit?.hasSpaceAtSides != true)
            Button("Zoom In") { model.zoom(in: true) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(noSheet || model.zoom >= GridGeometry.zoomSteps.last!)
            Button("Zoom Out") { model.zoom(in: false) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(noSheet || model.zoom <= GridGeometry.zoomSteps.first!)
            Divider()
            Toggle("Show Hidden Thumbs", isOn: model.setting(\.showHiddenThumbs))
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(noSheet)
            Toggle("Show Header", isOn: model.setting(\.showHeader))
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(noSheet || timeline)
            Picker("Thumb Label", selection: model.setting(\.frameInfo)) {
                Text("Frames").tag(FrameInfo.frames)
                Text("Timecode").tag(FrameInfo.timecode)
                Text("None").tag(FrameInfo.hidden)
            }
            .disabled(noSheet)
            Toggle("Show Face Rectangles", isOn: model.setting(\.showFaceRectangles))
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(sheet?.type != .faces)
            Divider()
            // Also key G (the key monitor).
            Button(timeline ? "Grid View" : "Timeline View") {
                if let ref = model.currentRef { model.toggleView(ref) }
            }
            .keyboardShortcut("g")
            .disabled(noSheet || sheet?.type == .faces)
            // Also key 2.
            Button(model.player.isShown ? "Hide Player View" : "Show Player View") { model.togglePlayerView() }
                .keyboardShortcut("2")
                .disabled(noSheet && !model.player.isShown)
            Toggle("Mean Colors Only", isOn: Binding(
                get: { !settings.timelineShowImages },
                set: { on in model.updateSettings { $0.timelineShowImages = !on } }))
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(noSheet || !timeline)
            Divider()
            // Also keys 1 and 3.
            Button(model.showMovieList ? "Hide Movie List" : "Show Movie List") { model.showMovieList.toggle() }
                .keyboardShortcut("1")
            Button(model.showSettings ? "Hide Settings Panel" : "Show Settings Panel") { model.showSettings.toggle() }
                .keyboardShortcut("3")
            Divider()
        }
        ToolbarCommands()
    }
}
