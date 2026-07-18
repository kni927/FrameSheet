import SwiftUI
import UniformTypeIdentifiers

// Phase 3a addressable grid: header strip + one ThumbnailCellView per
// Thumbnail, laid out with the same geometry as the exported sheet
// (cell size, spacing, header height all come from the renderer's
// metrics for the params snapshot the cell images were rendered with).
// Cells drag-reorder via onDrag/onDrop (deployment target is macOS 11,
// so the macOS 13+ .draggable API is not available).
struct ThumbnailGridView: View {
    @EnvironmentObject var state: AppState
    let params: GenerationParams

    @State private var draggingID: UUID? = nil

    var body: some View {
        let m = ContactSheetRenderer.metrics(for: params)
        let scale = state.zoomScale
        let cellW = CGFloat(m.cellW) * scale
        let cellH = CGFloat(m.cellH) * scale
        let spacing = CGFloat(params.spacing) * scale
        let gridWidth = CGFloat(params.imageWidth) * scale

        let columns = Array(
            repeating: GridItem(.fixed(cellW), spacing: spacing),
            count: params.cols
        )

        VStack(spacing: 0) {
            if let header = state.headerImage {
                Image(nsImage: header)
                    .resizable()
                    .frame(width: gridWidth, height: CGFloat(m.headerH) * scale)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(state.thumbnails) { thumb in
                    ThumbnailCellView(
                        thumbnail: thumb,
                        image: state.cellImages[thumb.id],
                        width: cellW,
                        height: cellH
                    )
                    .opacity(draggingID == thumb.id ? 0.4 : 1.0)
                    .onDrag {
                        draggingID = thumb.id
                        return NSItemProvider(object: thumb.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.plainText], delegate: CellReorderDropDelegate(
                        item: thumb, state: state, draggingID: $draggingID
                    ))
                }
            }
            .frame(width: gridWidth, alignment: .topLeading)
        }
        .background(params.bgColor)
    }
}

// Live-reorders the thumbnails array while a cell drag hovers other cells;
// the export order follows the array (sheet recomposed on drop).
struct CellReorderDropDelegate: DropDelegate {
    let item: Thumbnail
    let state: AppState
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != item.id,
              let from = state.thumbnails.firstIndex(where: { $0.id == dragging }),
              let to   = state.thumbnails.firstIndex(where: { $0.id == item.id })
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            state.thumbnails.move(fromOffsets: IndexSet(integer: from),
                                  toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        state.recomposeSheet()
        return true
    }
}
