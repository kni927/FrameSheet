import FrameSheetCore
import SwiftUI

/// Grid view of a sheet, laid out by `GridGeometry` (§5.1) to fit the main
/// area at zoom 1.
struct SheetGridView: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet

    var body: some View {
        let settings = model.library.settings
        let thumbs = settings.showHiddenThumbs ? sheet.thumbs : sheet.visibleThumbs
        GeometryReader { proxy in
            let padding: CGFloat = 16
            let geometry = GridGeometry(.init(
                movieWidth: Double(file.width), movieHeight: Double(file.height),
                aspectRatioInv: file.transform.aspectRatioInv, columnCount: sheet.columnCount,
                thumbCount: thumbs.count,
                containerWidth: max(1, proxy.size.width - padding * 2 - GridGeometry.minPrintWidthMargin),
                containerHeight: max(1, proxy.size.height - padding * 2),
                marginRatio: settings.marginRatio, showHeader: settings.showHeader,
                showPathInHeader: settings.showPathInHeader,
                showDetailsInHeader: settings.showDetailsInHeader,
                showTimelineInHeader: settings.showTimelineInHeader,
                roundedCorners: settings.roundedCorners))
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(Array(thumbs.enumerated()), id: \.element.id) { index, thumb in
                        let frame = geometry.thumbFrame(at: index)
                        ThumbView(file: file, thumb: thumb, cornerRadius: geometry.borderRadius)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: geometry.printWidth, height: geometry.printHeight)
                .padding(padding)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }
}

private struct ThumbView: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let thumb: Thumb
    let cornerRadius: Double

    var body: some View {
        Group {
            if let image = model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.thumbPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .opacity(thumb.hidden ? 0.3 : 1)
        .help("Frame \(thumb.frameNumber) · \(Timecode.string(frames: thumb.frameNumber, fps: file.fps))")
    }
}
