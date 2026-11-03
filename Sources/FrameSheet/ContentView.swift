import AppKit
import FrameSheetCore
import SwiftUI

/// The §4 window: movie list, main area with the sheet, settings sidebar and
/// the window toolbar (the sheet tools sit next to the title; there is no
/// footer, owner 2026-11-03).
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.showMovieList ? .all : .detailOnly },
            set: { model.showMovieList = $0 != .detailOnly }
        )) {
            MovieListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
                // Our own toggle sits after the app name instead.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            MainArea()
        }
        // On the split view rather than the detail, so the panel is a
        // full-height column like the movie list. Its toggle is in the sheet
        // tools, so it stays while the panel is hidden.
        .inspector(isPresented: $model.showSettings) {
            SettingsPanel()
                .inspectorColumnWidth(min: 280, ideal: 300, max: 380)
        }
        // The app name is a toolbar item at the far left instead (owner,
        // 2026-11-03), so the window title is not shown twice.
        .toolbar(removing: .title)
        .toolbar {
            // The app name, then the movie list toggle, then a gap before
            // the icon groups (owner, 2026-11-03).
            ToolbarItem(placement: .navigation) {
                HStack(spacing: Theme.space2) {
                    Text("FrameSheet")
                        .font(Theme.sans(15, medium: true))
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                    Button {
                        model.showMovieList.toggle()
                    } label: {
                        Label(model.showMovieList ? "Hide movie list" : "Show movie list", systemImage: "sidebar.left")
                    }
                    .buttonStyle(ToolbarIconStyle(selected: model.showMovieList))
                    .accessibilityAddTraits(model.showMovieList ? .isSelected : [])
                    .help(model.showMovieList ? "Hide movie list (1)" : "Show movie list (1)")
                }
                .padding(.leading, Theme.space3)
                .padding(.trailing, Theme.space4)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .navigation) {
                ToolbarIconGroup {
                    Button {
                        model.presentOpenPanel()
                    } label: {
                        Label("Add movies", systemImage: "plus")
                    }
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("Add movies (A)")
                    Menu {
                        Button("Import Sheet…") { model.presentImportPanel() }
                            .help("Import a PNG or JSON saved by FrameSheet or MoviePrint")
                        Divider()
                        Button("Clear movie list…", role: .destructive) { confirmingClear = true }
                            .disabled(model.library.files.isEmpty)
                            .help("Remove all movies and their sheets")
                    } label: {
                        Label("More options", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(ToolbarIconStyle(grouped: true))
                    .toolbarHelp("More options")
                }
                }
            .sharedBackgroundVisibility(.hidden)
            SheetToolbar(model: model, sheet: model.currentSheet)
        }
        .tint(Theme.accent)
        .font(Theme.bodySm)
        .foregroundStyle(Theme.text)
        .overlay(alignment: .bottom) { Toast() }
        // Key F and View → Detection Chart; Esc or F closes it.
        .sheet(item: $model.detectionChart) { chart in
            DetectionChartView(chart: chart)
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .alert("Clear the movie list?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { model.clearList() }
                .help("Remove all movies and their sheets")
            Button("Cancel", role: .cancel) {}
                .help("Keep the movie list")
        } message: {
            Text("All movies and their sheets are removed. Undo brings them back.")
        }
    }
}

/// Main area: the sheet grid or the empty state, the scrub overlay and the
/// drop target.
struct MainArea: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base
            if let file = model.currentFile, let sheet = model.currentSheet {
                if model.player.isShown {
                    PlayerView(file: file, sheet: sheet)
                } else if model.isTimeline(sheet) {
                    TimelineSheetView(file: file, sheet: sheet)
                } else {
                    SheetGridView(file: file, sheet: sheet)
                }
            } else {
                EmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let scrub = model.scrub, let file = model.currentFile {
                ScrubOverlay(session: scrub, file: file)
            }
            if isDropTargeted { DropOverlay() }
        }
        .coordinateSpace(.named(MainArea.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.mainAreaSize = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            // PNGs and JSON files are imported as sheets; the rest are
            // added as movies (Option clears the list first).
            model.openFiles(urls, clearFirst: NSEvent.modifierFlags.contains(.option))
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// Coordinate space of the main area; the scrub maps pointer X in it.
    static let space = "mainArea"
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: Theme.space2) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("Drop movies here or press A to add them")
                .font(Theme.body)
                .foregroundStyle(Theme.textMuted)
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        // Read while the drag is over the view; Option clears the list first.
        let clear = NSEvent.modifierFlags.contains(.option)
        ZStack {
            Theme.crust.opacity(0.85)
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                .padding(Theme.space6)
            Text(clear ? "CLEAR LIST AND ADD MOVIES" : "ADD MOVIES TO LIST")
                .font(Theme.heading1)
                .foregroundStyle(Theme.accentInk)
        }
        .allowsHitTesting(false)
    }
}

/// Save progress with Cancel, then the latest error, else a short notice.
private struct Toast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.space2) {
            if let scan = model.scanJob {
                ToastCard {
                    if let fraction = scan.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                    }
                    Text(scan.message)
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Button("Cancel") { model.cancelScan() }
                        .controlSize(.small)
                        .help("Stop shot detection; it can resume later")
                }
            }
            if let progress = model.progress {
                ToastCard {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text(progress.message)
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Button("Cancel") { model.cancelSave() }
                        .controlSize(.small)
                        .help("Stop saving")
                }
            }
            if let message = model.toast {
                ToastCard {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text(message)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    DismissButton { model.toast = nil }
                }
            } else if let message = model.notice {
                ToastCard {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.success)
                    Text(message)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    DismissButton { model.notice = nil }
                }
            }
        }
        .padding(.bottom, Theme.space6)
    }
}

private struct ToastCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space3) { content }
            .font(Theme.bodySm)
            .padding(Theme.space3)
            .frame(maxWidth: 520)
            .background(Theme.mantle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1))
    }
}

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textMuted)
        .help("Dismiss")
    }
}
