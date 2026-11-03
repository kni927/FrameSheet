import AppKit
import FrameSheetCore
import SwiftUI

/// Left sidebar (§4): one row per movie with its sheets under it.
struct MovieListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.library.files) { file in
                    MovieRow(file: file)
                    ForEach(model.sheets(of: file.id)) { sheet in
                        SheetRow(file: file, sheet: sheet)
                    }
                }
            }
            .padding(Theme.space2)
        }
        .background(Theme.crust)
        .overlay {
            if model.library.files.isEmpty {
                Text("No movies")
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

private struct MovieRow: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile

    var body: some View {
        let selected = model.library.currentFileId == file.id
        let missing = model.missing.contains(file.id)
        // The poster with the name beside it; the folder and the detail
        // line span the row under them.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: Theme.space2) {
                Poster(file: file)
                // Up to two lines, cut in the middle: names without spaces
                // wrap mid-word. The tooltips give the full text.
                Text(file.name)
                    .font(Theme.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(file.name)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            // The full path, cut in the middle to the row's width.
            Text(file.folder)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(file.folder)
            if missing {
                // In place of the detail line.
                Label("Movie is missing", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.danger)
                Button("Locate…") { model.locate(file.id) }
                    .controlSize(.small)
                    .help("Find the moved movie")
                    .padding(.top, 2)
            } else {
                Text(details)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(details)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.space2 - 2)
        .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .contentShape(Rectangle())
        .onTapGesture { model.select(file: file.id) }
        .help(file.url.path)
        .contextMenu {
            Button("Open File Location") { model.revealInFinder(file) }
                .disabled(missing)
            if missing {
                Button("Locate…") { model.locate(file.id) }
            }
            Divider()
            Button("Remove", role: .destructive) { model.removeMovie(file.id) }
        }
    }
}

extension MovieRow {
    /// Duration · width×height · size, on one line.
    fileprivate var details: String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        return "\(Timecode.string(seconds: file.duration)) · \(file.width)×\(file.height) · \(size)"
    }
}

private struct Poster: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile

    var body: some View {
        let width: CGFloat = 80
        let ratio = file.width > 0 ? CGFloat(file.height) / CGFloat(file.width) : 9 / 16
        Group {
            if let image = model.image(file: file.id, frame: file.posterFrame, width: AppModel.posterWidth) {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Theme.surface
            }
        }
        .frame(width: width, height: width * ratio)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
    }
}

private struct SheetRow: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let selected = model.library.currentSheetId == sheet.id
        let ref = SheetRef(fileId: file.id, sheetId: sheet.id)
        HStack(spacing: Theme.space2) {
            Image(systemName: sheet.view == .grid ? "square.grid.3x3" : "barcode")
                .foregroundStyle(selected ? Theme.accentInk : Theme.textMuted)
            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.caption)
                    .padding(.horizontal, Theme.space1)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.focus, lineWidth: 1))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit { commit(ref) }
                    .onExitCommand { isRenaming = false }
                    .onChange(of: fieldFocused) { _, focused in
                        model.isEditingText = focused
                        if !focused && isRenaming { commit(ref) }
                    }
                    .onDisappear { model.isEditingText = false }
            } else {
                // The name keeps its room before the type label.
                Text(sheet.name)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help(sheet.name)
            }
            Spacer(minLength: Theme.space1)
            Text(shortLabel(sheet.type))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .help(sheet.type.label)
        }
        .font(Theme.caption)
        .padding(.vertical, Theme.space1)
        .padding(.leading, Theme.space6)
        .padding(.trailing, Theme.space2)
        .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .contentShape(Rectangle())
        .onTapGesture { model.select(sheet: sheet.id, of: file.id) }
        .contextMenu {
            Button("Rename") { startRenaming() }
            // Come with the timeline view and shot sheets (T05).
            Button("Switch View") {}.disabled(true)
            Button("Convert to Interval") {}.disabled(true)
            Button("Duplicate") { model.duplicateSheet(ref) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteSheet(ref) }
        }
    }

    private func shortLabel(_ type: SheetType) -> String {
        switch type {
        case .interval: "Interval"
        case .shot: "Shots"
        case .faces: "Faces"
        }
    }

    private func startRenaming() {
        draft = sheet.name
        isRenaming = true
    }

    private func commit(_ ref: SheetRef) {
        isRenaming = false
        model.renameSheet(ref, to: draft)
    }
}
