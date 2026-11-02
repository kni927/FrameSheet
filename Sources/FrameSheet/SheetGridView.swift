import AppKit
import FrameSheetCore
import SwiftUI

/// Grid view of a sheet, laid out by `GridGeometry` (§5.1) to fit the main
/// area at zoom 1, with the §7 thumb interactions.
struct SheetGridView: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    /// The hover button under the pointer, for dimming the thumbs it affects.
    @State private var hoverButton: (thumb: UUID, button: HoverButton)?

    var body: some View {
        let settings = model.library.settings
        let thumbs = model.shownThumbs(of: sheet)
        let dimmed = hoverButton.map { Sheet.affectedThumbs($0.button, of: $0.thumb, in: thumbs) } ?? []
        GeometryReader { proxy in
            let padding = Theme.space4
            // Room at the top for the floating toolbar.
            let top = Theme.space12
            let geometry = GridGeometry(.init(
                movieWidth: Double(file.width), movieHeight: Double(file.height),
                aspectRatioInv: file.transform.aspectRatioInv, columnCount: sheet.columnCount,
                thumbCount: thumbs.count,
                containerWidth: max(1, proxy.size.width - padding * 2 - GridGeometry.minPrintWidthMargin),
                containerHeight: max(1, proxy.size.height - padding - top),
                zoom: model.zoom, marginRatio: settings.marginRatio, showHeader: settings.showHeader,
                showPathInHeader: settings.showPathInHeader,
                showDetailsInHeader: settings.showDetailsInHeader,
                showTimelineInHeader: settings.showTimelineInHeader,
                roundedCorners: settings.roundedCorners))
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(Array(thumbs.enumerated()), id: \.element.id) { index, thumb in
                        let frame = geometry.thumbFrame(at: index)
                        ThumbView(
                            file: file, sheet: sheet, thumb: thumb, size: frame.size,
                            cornerRadius: geometry.borderRadius, dimmed: dimmed.contains(thumb.id),
                            onHoverButton: { button in
                                hoverButton = button.map { (thumb.id, $0) }
                            })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: geometry.printWidth, height: geometry.printHeight)
                .padding(.horizontal, padding)
                .padding(.top, top)
                .padding(.bottom, padding)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }
}

private struct ThumbView: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    let thumb: Thumb
    let size: CGSize
    let cornerRadius: Double
    let dimmed: Bool
    let onHoverButton: (HoverButton?) -> Void
    @State private var hovering = false
    @State private var isDropTarget = false

    /// Below this width the hover overlay is hidden; below `compactWidth` it
    /// is drawn at 0.7 (§7).
    static let minOverlayWidth: CGFloat = 100
    static let compactWidth: CGFloat = 160

    var body: some View {
        let selected = model.selectedThumbId == thumb.id
        let scrubbing = model.scrub?.thumbId == thumb.id
        let showOverlay = (hovering || scrubbing) && size.width >= Self.minOverlayWidth
            && (model.scrub == nil || scrubbing)
        ZStack {
            if let image = model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.surface
            }
        }
        .frame(width: size.width, height: size.height)
        // On the image only: a tooltip on the whole thumb would replace the
        // hover buttons' own tooltips.
        .help("Frame \(thumb.frameNumber) · \(Timecode.string(frames: thumb.frameNumber, fps: file.fps))")
        .overlay { FrameInfoLabel(file: file, thumb: thumb, thumbHeight: size.height) }
        .overlay { if dimmed { Theme.crust.opacity(0.65) } }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .opacity(thumb.hidden ? 0.3 : 1)
        .overlay {
            if showOverlay {
                HoverOverlay(
                    file: file, sheet: sheet, thumb: thumb, compact: size.width < Self.compactWidth,
                    onHoverButton: onHoverButton)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.focus, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { onHoverButton(nil) }
        }
        .onTapGesture { model.selectedThumbId = thumb.id }
        .draggable(thumb.id.uuidString)
        .dropDestination(for: String.self) { items, location in
            // The left half drops before this thumb, the right half after.
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.moveThumb(dragged, onto: thumb.id, after: location.x > size.width / 2)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}

/// The frame number or timecode on a thumb, per the frame info settings.
private struct FrameInfoLabel: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let thumb: Thumb
    let thumbHeight: CGFloat

    var body: some View {
        let settings = model.library.settings
        if let text = FrameInfoText.text(settings.frameInfo, frame: thumb.frameNumber, fps: file.fps) {
            let size = max(1, FrameInfoText.fontSize(size: settings.frameInfoSize, thumbHeight: thumbHeight))
            Text(text)
                .font(Theme.mono(size, medium: true))
                .foregroundStyle(Color(settings.frameInfoColor))
                .padding(.horizontal, size * 0.3)
                .padding(.vertical, size * 0.1)
                .background(Color(settings.frameInfoBackground))
                .padding(settings.frameInfoMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(settings.frameInfoPosition))
                .allowsHitTesting(false)
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

/// Buttons over a hovered thumb (§7): IN and OUT on top, insert before and
/// after at the sides, the scrub handle in the middle, EXPAND and Hide/Show
/// at the bottom. Option-click on IN/OUT hides all before/after.
private struct HoverOverlay: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    let thumb: Thumb
    let compact: Bool
    let onHoverButton: (HoverButton?) -> Void

    var body: some View {
        let isInterval = sheet.type == .interval
        VStack(spacing: 0) {
            HStack {
                OverlayButton(title: hideMode ? "◀ HIDE" : "IN", help: isInterval
                    ? "IN: start the sheet at this frame and recapture the same number of thumbs up to the last one.\n⌥-click: hide all thumbs before this one."
                    : "Hide all thumbs before this one.", report: { onHoverButton($0 ? .inPoint : nil) }) {
                    model.setInOut(.before, thumb: thumb.id, option: optionHeld)
                }
                Spacer()
                OverlayButton(title: hideMode ? "HIDE ▶" : "OUT", help: isInterval
                    ? "OUT: end the sheet at this frame and recapture the same number of thumbs from the first one.\n⌥-click: hide all thumbs after this one."
                    : "Hide all thumbs after this one.", report: { onHoverButton($0 ? .outPoint : nil) }) {
                    model.setInOut(.after, thumb: thumb.id, option: optionHeld)
                }
            }
            Spacer(minLength: 0)
            HStack {
                OverlayButton(systemImage: "plus", help: "Insert a thumb before this one, at the frame midway to the previous thumb.", report: { onHoverButton($0 ? .insertBefore : nil) }) {
                    model.insertThumb(.before, relativeTo: thumb.id)
                }
                Spacer()
                ScrubHandle(thumb: thumb)
                Spacer()
                OverlayButton(systemImage: "plus", help: "Insert a thumb after this one, at the frame midway to the next thumb.", report: { onHoverButton($0 ? .insertAfter : nil) }) {
                    model.insertThumb(.after, relativeTo: thumb.id)
                }
            }
            Spacer(minLength: 0)
            HStack {
                OverlayButton(title: "EXPAND", help: "EXPAND: open a new sheet of 16 thumbs between this thumb's neighbours. Back to parent (toolbar) returns.", report: { onHoverButton($0 ? .expand : nil) }) {
                    model.expand(thumb.id)
                }
                Spacer()
                OverlayButton(systemImage: thumb.hidden ? "eye" : "eye.slash", help: thumb.hidden ? "Show this thumb again." : "Hide this thumb (Show hidden thumbs in the toolbar shows it dimmed).", report: { onHoverButton($0 ? .hide : nil) }) {
                    onHoverButton(nil)
                    model.toggleHidden(thumb.id)
                }
            }
        }
        .padding(Theme.space1)
        .environment(\.overlayScale, compact ? 0.7 : 1)
    }

    /// Option at the moment of the click: the click event carries it.
    private var optionHeld: Bool {
        model.optionHeld || (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.option)
    }

    /// IN/OUT hide all before/after: with Option, or on other sheet types.
    /// The labels say so, which MoviePrint only did in the tooltip.
    private var hideMode: Bool { model.optionHeld || sheet.type != .interval }
}

private struct OverlayButton: View {
    var title: String?
    var systemImage: String?
    let help: String
    /// Tells the grid which hover button the pointer is over (dimming).
    var report: (Bool) -> Void = { _ in }
    let action: () -> Void
    @Environment(\.overlayScale) private var scale
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(Theme.sans(11 * scale, medium: true))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11 * scale, weight: .semibold))
                }
            }
            .foregroundStyle(hovering ? Theme.onAccent : Theme.text)
            .padding(.horizontal, (Theme.space1 + 2) * scale)
            .frame(minWidth: 22 * scale, minHeight: 20 * scale)
            .background(hovering ? Theme.accent : Theme.crust.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One onHover for both the highlight and the dimming report: a second
        // onHover stacked on the same view is not called.
        .onHover { inside in
            hovering = inside
            report(inside)
        }
        .help(help)
    }
}

/// Drag it to scrub (§7). The drag reports its location in the main area's
/// coordinate space, where the scrub overlay is drawn.
private struct ScrubHandle: View {
    @Environment(AppModel.self) private var model
    let thumb: Thumb
    @Environment(\.overlayScale) private var scale

    var body: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 36 * scale, height: 22 * scale)
            .background(Theme.accent, in: Capsule())
            .contentShape(Capsule())
            .help("Scrub: drag left/right to pick another frame between the neighbours; release to CHANGE TO it.\nHold ⇧ to ADD BEFORE, ⌥ to ADD AFTER, ⌃ to reach the start or end of the movie.\nClick and release to scrub without holding the button; click again to confirm, Esc cancels.")
            .highPriorityGesture(
                // Starts on mouse-down, so the thumb's own drag (reorder)
                // cannot take it; a quick click leaves the scrub open.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(MainArea.space))
                    .onChanged { value in
                        let modifiers = ScrubModifiers(NSEvent.modifierFlags)
                        if model.scrub == nil {
                            model.beginScrub(
                                thumb.id, keyboard: false, modifiers: modifiers, x: value.location.x,
                                y: value.location.y)
                        } else {
                            model.scrubMoved(x: value.location.x, y: value.location.y, modifiers: modifiers)
                        }
                    }
                    .onEnded { value in
                        model.scrubMoved(
                            x: value.location.x, y: value.location.y,
                            modifiers: ScrubModifiers(NSEvent.modifierFlags))
                        model.releaseScrub()
                    })
    }
}

extension ScrubModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ScrubModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}

extension EnvironmentValues {
    /// 0.7 for the compact hover overlay on narrow thumbs.
    @Entry var overlayScale: CGFloat = 1
}
