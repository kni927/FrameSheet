import AppKit
import FrameSheetCore
import SwiftUI

/// The §4 window: movie list, main area with the sheet, settings sidebar,
/// header and footer.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.showMovieList ? .all : .detailOnly },
            set: { model.showMovieList = $0 != .detailOnly }
        )) {
            MovieListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            MainArea()
                .inspector(isPresented: $model.showSettings) {
                    SettingsPanel()
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Add movies", systemImage: "plus")
                }
                .help("Add movies (A)")
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Import MoviePrint…") {}.disabled(true)
                    Divider()
                    Button("Clear movie list", role: .destructive) { model.clearList() }
                        .disabled(model.library.files.isEmpty)
                } label: {
                    Label("More options", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "sidebar.right")
                }
                .help("Settings (3)")
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { Toast() }
    }
}

/// Main area: the sheet grid or the empty state, the drop target and the
/// footer.
struct MainArea: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.windowBackground
                if let file = model.currentFile, let sheet = model.currentSheet {
                    SheetGridView(file: file, sheet: sheet)
                } else {
                    EmptyState()
                }
                if isDropTargeted { DropOverlay() }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.addMovies(urls, clearFirst: NSEvent.modifierFlags.contains(.option))
                return true
            } isTargeted: { isDropTargeted = $0 }
            Footer()
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(Theme.overlay1)
            Text("Drop movies here or press A to add them")
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        // Read while the drag is over the view; Option clears the list first.
        let clear = NSEvent.modifierFlags.contains(.option)
        ZStack {
            Theme.crust.opacity(0.85)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(24)
            Text(clear ? "CLEAR LIST AND ADD MOVIES" : "ADD MOVIES TO LIST")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .allowsHitTesting(false)
    }
}

private struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            if let sheet = model.currentSheet {
                let count = sheet.visibleThumbs.count
                let rows = Int((Double(count) / Double(max(1, sheet.columnCount))).rounded(.up))
                Text("\(sheet.columnCount) Columns × \(rows) Rows = \(count)")
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Save MoviePrint") {}
                .disabled(true)
                .help("Save MoviePrint (M) — not built yet")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.mantle)
    }
}

private struct Toast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.toast {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.peach)
                Text(message)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
            }
            .padding(12)
            .frame(maxWidth: 520)
            .background(Theme.surface0, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 52)
        }
    }
}
