import SwiftUI

// One grid cell. The base image is pre-rendered by
// ContactSheetRenderer.renderCellImage (same drawing code as the export),
// so the cell shows exactly what the sheet will contain. Stage B adds a
// hover overlay (scrim + timestamp + hide toggle); hidden cells stay in
// the grid dimmed and are excluded from the exported sheet.
struct ThumbnailCellView: View {
    @EnvironmentObject var state: AppState
    let thumbnail: Thumbnail
    let image: NSImage?
    let width: CGFloat
    let height: CGFloat

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Group {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                } else {
                    Color(white: 0.12)
                }
            }
            .opacity(thumbnail.hidden ? 0.25 : 1.0)

            // Persistent marker on hidden cells (visible without hover)
            if thumbnail.hidden && !isHovering {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: min(width, height) * 0.18))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(radius: 2)
            }

            if isHovering {
                Color.black.opacity(0.35)

                VStack(spacing: 6) {
                    Text(ContactSheetRenderer.formatTimestamp(thumbnail.timestamp))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(radius: 2)

                    Button(action: {
                        state.toggleHidden(thumbnail.id)
                    }) {
                        Image(systemName: thumbnail.hidden ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: min(width, height) * 0.16))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help(thumbnail.hidden ? "Unhide this thumbnail" : "Hide this thumbnail (excluded from export)")
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
