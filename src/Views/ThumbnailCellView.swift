import SwiftUI

// One grid cell. Stage A: display only — the image is pre-rendered by
// ContactSheetRenderer.renderCellImage (same drawing code as the export),
// so the cell shows exactly what the sheet will contain.
struct ThumbnailCellView: View {
    let thumbnail: Thumbnail
    let image: NSImage?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
            } else {
                Color(white: 0.12)
            }
        }
        .frame(width: width, height: height)
    }
}
