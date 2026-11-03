import FrameSheetCore
import SwiftUI

/// The print of a sheet: background, header and thumbs with their frame
/// info laid out by `GridGeometry` (§5.1, §5.2), or the timeline's scene
/// boxes laid out by `TimelineGeometry` (§6, §10). The window draws it under
/// its interaction layer and Save Sheet renders it offscreen with
/// `ImageRenderer`, so both show the same print. It reads nothing from the
/// environment; images come from `image`.
struct PrintView: View {
    let file: MovieFile
    /// Grid: the thumbs in print order; hidden ones are drawn dimmed.
    /// Timeline: the thumbs of the scenes (a scene's thumb has its id).
    let thumbs: [Thumb]
    let layout: PrintLayout
    let settings: FrameSheetCore.Settings
    let image: (Thumb) -> CGImage?

    var body: some View {
        switch layout {
        case .grid(let geometry):
            grid(geometry)
        case .timeline(let geometry, let scenes):
            timeline(geometry, scenes: scenes)
        }
    }

    private func grid(_ geometry: GridGeometry) -> some View {
        let size = geometry.printContentSize
        return ZStack(alignment: .topLeading) {
            Color(PrintOutput.background(settings.outputBackground, format: settings.outputFormat))
            if settings.showHeader {
                let frame = geometry.headerFrame
                PrintHeaderView(
                    file: file, frameNumbers: thumbs.map(\.frameNumber), settings: settings,
                    logoHeight: geometry.logoHeight, cornerRadius: geometry.borderRadius)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            ForEach(Array(thumbs.enumerated()), id: \.element.id) { index, thumb in
                let frame = geometry.thumbFrame(at: index)
                PrintThumb(
                    file: file, thumb: thumb, image: image(thumb), settings: settings, size: frame.size,
                    cornerRadius: geometry.borderRadius)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The timeline (MoviePrint `SceneGrid`/`Scene`): one box per scene,
    /// its mean color under the scene's frame (unless Toggle images shows
    /// colors only), the frame info of its thumb, dimmed when hidden.
    private func timeline(_ geometry: TimelineGeometry, scenes: [FrameSheetCore.Scene]) -> some View {
        let size = geometry.contentSize
        let byId = Dictionary(thumbs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            Color(PrintOutput.background(settings.outputBackground, format: settings.outputFormat))
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                let frame = geometry.sceneFrames[index]
                let thumb = byId[scene.id]
                PrintScene(
                    file: file, scene: scene, thumb: thumb,
                    image: settings.timelineShowImages ? thumb.flatMap(image) : nil, settings: settings,
                    size: frame.size, cornerRadius: min(geometry.borderRadius, frame.width / 2))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// One scene box of the timeline: the mean color, the frame filling the
/// box's height and centered (cropped at the sides), and its frame info.
private struct PrintScene: View {
    let file: MovieFile
    let scene: FrameSheetCore.Scene
    let thumb: Thumb?
    let image: CGImage?
    let settings: FrameSheetCore.Settings
    let size: CGSize
    let cornerRadius: Double

    var body: some View {
        let color = scene.colorRGB.count == 3
            ? Color(.sRGB, red: Double(scene.colorRGB[0]) / 255, green: Double(scene.colorRGB[1]) / 255,
                    blue: Double(scene.colorRGB[2]) / 255)
            : Theme.surface
        ZStack {
            color
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            if let thumb {
                FrameInfoLabel(file: file, thumb: thumb, settings: settings, thumbHeight: size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .opacity(scene.hidden ? 0.3 : 1)
    }
}

/// One thumb of the print: the frame, its frame info, rounded corners, and
/// dimmed when hidden.
private struct PrintThumb: View {
    let file: MovieFile
    let thumb: Thumb
    let image: CGImage?
    let settings: FrameSheetCore.Settings
    let size: CGSize
    let cornerRadius: Double

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.surface
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay { FrameInfoLabel(file: file, thumb: thumb, settings: settings, thumbHeight: size.height) }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .opacity(thumb.hidden ? 0.3 : 1)
    }
}

/// The frame number or timecode on a thumb or scene, per the Thumb label
/// settings; the window and the saved print both draw it.
private struct FrameInfoLabel: View {
    let file: MovieFile
    let thumb: Thumb
    let settings: FrameSheetCore.Settings
    let thumbHeight: CGFloat

    var body: some View {
        if let text = FrameInfoText.text(
            settings.frameInfo, frame: thumb.frameNumber, fps: file.fps,
            timecodeFormat: settings.frameInfoTimecodeFormat, frameFormat: settings.frameInfoFrameFormat,
            frameCount: file.frameCount) {
            let size = max(1, FrameInfoText.fontSize(size: settings.frameInfoSize, thumbHeight: thumbHeight))
            Text(text)
                .font(font(settings.frameInfoFontFamily, size: size))
                .foregroundStyle(Color(settings.frameInfoColor))
                .padding(.horizontal, size * 0.3)
                .padding(.vertical, size * 0.1)
                .background(Color(settings.frameInfoBackground))
                .padding(.horizontal, settings.frameInfoMarginHorizontal)
                .padding(.vertical, settings.frameInfoMarginVertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(settings.frameInfoPosition))
                .allowsHitTesting(false)
        }
    }

    /// The system designs, or an installed family by name (any family the
    /// owner picks; a missing one falls back to the system font).
    private func font(_ family: String, size: Double) -> Font {
        switch family {
        case FrameInfoFamily.system: Theme.sans(size, medium: true)
        case FrameInfoFamily.systemCondensed: Theme.condensed(size, weight: .medium)
        case FrameInfoFamily.systemMono: Theme.mono(size, medium: true)
        default: Font.custom(family, size: size).weight(.medium)
        }
    }

    private func alignment(_ position: FrameInfoPosition) -> Alignment {
        switch position {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .centerCenter: .center
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

/// The print header (§5.2) in MoviePrint's layout (`ThumbGridHeader`)
/// without its logo or an app icon (owner, 2026-11-03): the file name with
/// the optional folder and details lines, right-aligned as in MoviePrint or
/// left-aligned (`headerAlignment`) over the full width, and the optional
/// mini timeline under them. Sizes are `PrintHeader.Metrics` of the logo
/// band; colors are kni tokens.
struct PrintHeaderView: View {
    let file: MovieFile
    /// The print's thumbs, for the timeline.
    let frameNumbers: [Int]
    let settings: FrameSheetCore.Settings
    let logoHeight: Double
    let cornerRadius: Double

    var body: some View {
        let m = PrintHeader.Metrics(logoHeight: logoHeight)
        let right = settings.headerAlignment == .right
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: right ? .trailing : .leading, spacing: 0) {
                Text(file.name)
                    .font(.system(size: max(1, m.titleSize), weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .minimumScaleFactor(PrintHeader.Metrics.titleMinimumScale)
                    .frame(height: m.titleLineHeight)
                    .padding(.bottom, m.titleSpacing)
                if settings.showPathInHeader {
                    line(PrintHeader.folderLine(file: file), metrics: m)
                }
                if settings.showDetailsInHeader {
                    line(PrintHeader.detailsLine(file: file), metrics: m)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
            if settings.showTimelineInHeader {
                HeaderTimeline(
                    timeline: PrintHeader.timeline(frameNumbers: frameNumbers, frameCount: file.frameCount),
                    tickWidth: max(1, logoHeight * 0.01))
                    .frame(height: m.timelineHeight)
            }
        }
        .padding(.top, m.unit)
        .padding(.horizontal, m.unit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.mantle, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func line(_ text: String, metrics m: PrintHeader.Metrics) -> some View {
        Text(text)
            .font(.system(size: max(1, m.unit)))
            .foregroundStyle(Theme.textMuted)
            .frame(height: m.lineHeight)
    }
}

/// The header's mini timeline: a faint track, the range from the first to
/// the last thumb, and a tick per thumb.
private struct HeaderTimeline: View {
    let timeline: PrintHeader.Timeline
    let tickWidth: Double

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.text.opacity(0.2)))
            let range = CGRect(
                x: timeline.rangeStart * size.width, y: 0, width: timeline.rangeWidth * size.width,
                height: size.height)
            context.fill(Path(range), with: .color(Theme.accent))
            for position in timeline.thumbPositions {
                let x = min(position * size.width, size.width - tickWidth)
                context.fill(
                    Path(CGRect(x: x, y: 0, width: tickWidth, height: size.height)), with: .color(Theme.text))
            }
        }
    }
}
