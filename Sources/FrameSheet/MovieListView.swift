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
            .padding(8)
        }
        .background(Theme.sidebarBackground)
        .overlay {
            if model.library.files.isEmpty {
                Text("No movies")
                    .foregroundStyle(Theme.secondaryText)
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
        HStack(alignment: .top, spacing: 10) {
            Poster(file: file)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                Text(file.folder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if missing {
                    Text("Movie is missing").foregroundStyle(Theme.red)
                } else {
                    Text(Timecode.string(frames: file.frameCount, fps: file.fps))
                    Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.width)×\(file.height)")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(selected ? Theme.surface0 : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.select(file: file.id) }
        .help(file.url.path)
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
                Theme.thumbPlaceholder
            }
        }
        .frame(width: width, height: width * ratio)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct SheetRow: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet

    var body: some View {
        let selected = model.library.currentSheetId == sheet.id
        HStack(spacing: 8) {
            Image(systemName: sheet.view == .grid ? "square.grid.3x3" : "barcode")
                .foregroundStyle(selected ? Theme.accent : Theme.overlay1)
            Text(sheet.name)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text(sheet.type.label)
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.caption)
        .padding(.vertical, 4)
        .padding(.leading, 24)
        .padding(.trailing, 8)
        .background(selected ? Theme.surface1.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.select(sheet: sheet.id, of: file.id) }
    }
}
