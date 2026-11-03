import AppKit
import FrameSheetCore
import SwiftUI

/// The print of a grid sheet (§5.1, §5.2): background, header and thumbs
/// with their frame info, laid out by `GridGeometry`. The window draws it
/// under its interaction layer and Save MoviePrint renders it offscreen
/// with `ImageRenderer`, so both show the same print. It reads nothing from
/// the environment; images come from `image`.
struct PrintView: View {
    let file: MovieFile
    /// The thumbs in print order; hidden ones are drawn dimmed.
    let thumbs: [Thumb]
    let geometry: GridGeometry
    let settings: FrameSheetCore.Settings
    let image: (Thumb) -> CGImage?

    var body: some View {
        let size = geometry.printContentSize
        ZStack(alignment: .topLeading) {
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

/// The frame number or timecode on a thumb, per the frame info settings.
private struct FrameInfoLabel: View {
    let file: MovieFile
    let thumb: Thumb
    let settings: FrameSheetCore.Settings
    let thumbHeight: CGFloat

    var body: some View {
        if let text = FrameInfoText.text(settings.frameInfo, frame: thumb.frameNumber, fps: file.fps) {
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

/// The print header (§5.2) in MoviePrint's layout (`ThumbGridHeader`): the
/// app icon at the left, the file name with the optional folder and details
/// lines right-aligned at the right, the optional mini timeline under both.
/// Sizes are `PrintHeader.Metrics` of the logo band; colours are kni tokens.
struct PrintHeaderView: View {
    let file: MovieFile
    /// The print's thumbs, for the timeline.
    let frameNumbers: [Int]
    let settings: FrameSheetCore.Settings
    let logoHeight: Double
    let cornerRadius: Double

    var body: some View {
        let m = PrintHeader.Metrics(logoHeight: logoHeight)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: m.unit) {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: m.imageSize, height: m.imageSize)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
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
            }
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

    /// The FrameSheet icon from the bundle; also available in an offscreen
    /// render, which runs in the app.
    @MainActor static var appIcon: NSImage {
        NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage ?? NSImage()
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
