import SwiftUI

// Phase 3a addressable grid: header strip + one ThumbnailCellView per
// Thumbnail, laid out with the same geometry as the exported sheet
// (cell size, spacing, header height all come from the renderer's
// metrics for the params snapshot the cell images were rendered with).
struct ThumbnailGridView: View {
    @EnvironmentObject var state: AppState
    let params: GenerationParams

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
                }
            }
            .frame(width: gridWidth, alignment: .topLeading)
        }
        .background(params.bgColor)
    }
}
