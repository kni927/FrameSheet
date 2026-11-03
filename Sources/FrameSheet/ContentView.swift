import AppKit
import FrameSheetCore
import SwiftUI

/// The §4 window: movie list, main area with the sheet, settings sidebar and
/// the window toolbar (the sheet tools sit next to the title; there is no
/// footer, owner 2026-11-03).
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.showMovieList ? .all : .detailOnly },
            set: { model.showMovieList = $0 != .detailOnly }
        )) {
            MovieListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            MainArea()
        }
        // On the split view rather than the detail, so the panel is a
        // full-height column like the movie list, with its own part of the
        // toolbar.
        .inspector(isPresented: $model.showSettings) {
            SettingsPanel()
                .inspectorColumnWidth(min: 280, ideal: 300, max: 380)
        }
        // The app name is a toolbar item at the far left instead (owner,
        // 2026-11-03), so the window title is not shown twice.
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("FrameSheet")
                    .font(Theme.sans(15, medium: true))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Theme.space1)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Add movies", systemImage: "plus")
                }
                .buttonStyle(ToolbarIconStyle())
                .help("Add movies (A)")
                Menu {
                    Button("Import MoviePrint…") {}.disabled(true)
                    Divider()
                    Button("Clear movie list", role: .destructive) { model.clearList() }
                        .disabled(model.library.files.isEmpty)
                } label: {
                    Label("More options", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ToolbarIconStyle())
                .help("More options")
            }
            .sharedBackgroundVisibility(.hidden)
            SheetToolbar(model: model, sheet: model.currentSheet)
            // While the panel is shown its own toolbar part carries the
            // button, at the panel's leading edge.
            if !model.showSettings {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.showSettings = true
                    } label: {
                        Label("Show panel", systemImage: "sidebar.right")
                    }
                    .buttonStyle(ToolbarIconStyle())
                    .help("Show panel (3)")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .tint(Theme.accent)
        .font(Theme.bodySm)
        .foregroundStyle(Theme.text)
        .overlay(alignment: .bottom) { Toast() }
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
                SheetGridView(file: file, sheet: sheet)
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
            model.addMovies(urls, clearFirst: NSEvent.modifierFlags.contains(.option))
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

private struct Toast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.toast {
            HStack(alignment: .top, spacing: Theme.space3) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                Text(message)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Dismiss")
            }
            .font(Theme.bodySm)
            .padding(Theme.space3)
            .frame(maxWidth: 520)
            .background(Theme.mantle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.bottom, Theme.space6)
        }
    }
}
