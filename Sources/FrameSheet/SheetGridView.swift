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
            let top = padding
            let geometry = GridGeometry(.init(
                movieWidth: Double(file.width), movieHeight: Double(file.height),
                aspectRatioInv: file.transform.aspectRatioInv, columnCount: sheet.columnCount,
                thumbCount: thumbs.count,
                containerWidth: max(1, proxy.size.width - padding * 2 - GridGeometry.minPrintWidthMargin),
                containerHeight: max(1, proxy.size.height - padding - top),
                zoom: model.zoom, marginRatioHorizontal: settings.marginRatioHorizontal,
                marginRatioVertical: settings.marginRatioVertical, showHeader: settings.showHeader,
                showPathInHeader: settings.showPathInHeader,
                showDetailsInHeader: settings.showDetailsInHeader,
                showTimelineInHeader: settings.showTimelineInHeader,
                borderRadiusRatio: settings.borderRadiusRatio))
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

    /// Below this width the hover overlay is hidden (§7).
    static let minOverlayWidth: CGFloat = 100

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
                HoverOverlay(file: file, sheet: sheet, thumb: thumb, size: size, onHoverButton: onHoverButton)
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

/// Buttons over a hovered thumb (§7): IN and OUT on top, insert before and
/// after at the sides, the scrub handle in the middle, EXPAND and Hide/Show
/// at the bottom. Option-click on IN/OUT hides all before/after. Drawn as in
/// MoviePrint: faint white over the thumb, solid white under the pointer,
/// with a dark shadow instead of a backdrop (owner, 2026-11-03).
private struct HoverOverlay: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    let thumb: Thumb
    let size: CGSize
    let onHoverButton: (HoverButton?) -> Void

    /// Font size of the overlay's text and icons: relative to the thumb
    /// (height, and width so a row still fits), within 9–24 pt.
    static func unit(for size: CGSize) -> CGFloat {
        min(max(min(size.height * 0.11, size.width * 0.065), 9), 24)
    }

    var body: some View {
        let isInterval = sheet.type == .interval
        VStack(spacing: 0) {
            HStack {
                OverlayButton(
                    title: hideMode ? "◀ HIDE" : "IN",
                    help: isInterval ? "IN — start here (⌥ hide before)" : "Hide all before",
                    report: { onHoverButton($0 ? .inPoint : nil) }
                ) {
                    model.setInOut(.before, thumb: thumb.id, option: optionHeld)
                }
                Spacer()
                OverlayButton(
                    title: hideMode ? "HIDE ▶" : "OUT",
                    help: isInterval ? "OUT — end here (⌥ hide after)" : "Hide all after",
                    report: { onHoverButton($0 ? .outPoint : nil) }
                ) {
                    model.setInOut(.after, thumb: thumb.id, option: optionHeld)
                }
            }
            Spacer(minLength: 0)
            HStack {
                OverlayButton(systemImage: "plus", help: "Insert before", report: { onHoverButton($0 ? .insertBefore : nil) }) {
                    model.insertThumb(.before, relativeTo: thumb.id)
                }
                Spacer()
                ScrubHandle(thumb: thumb)
                Spacer()
                OverlayButton(systemImage: "plus", help: "Insert after", report: { onHoverButton($0 ? .insertAfter : nil) }) {
                    model.insertThumb(.after, relativeTo: thumb.id)
                }
            }
            Spacer(minLength: 0)
            HStack {
                OverlayButton(title: "EXPAND", help: "Expand to 16 thumbs", report: { onHoverButton($0 ? .expand : nil) }) {
                    model.expand(thumb.id)
                }
                Spacer()
                OverlayButton(
                    systemImage: thumb.hidden ? "eye" : "eye.slash", help: thumb.hidden ? "Show thumb" : "Hide thumb",
                    report: { onHoverButton($0 ? .hide : nil) }
                ) {
                    onHoverButton(nil)
                    model.toggleHidden(thumb.id)
                }
            }
        }
        .padding(Self.unit(for: size) * 0.3)
        .environment(\.overlayUnit, Self.unit(for: size))
    }

    /// Option at the moment of the click: the click event carries it.
    private var optionHeld: Bool {
        model.optionHeld || (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.option)
    }

    /// IN/OUT hide all before/after: with Option, or on other sheet types.
    /// The labels say so, which MoviePrint only did in the tooltip.
    private var hideMode: Bool { model.optionHeld || sheet.type != .interval }
}

/// Text and icon style of the hover overlay: condensed semibold white, half
/// opaque until the pointer is over it, then solid and slightly larger.
/// White is outside the kni tokens, an exception the owner approved for
/// legibility on any frame.
private struct OverlayLabel: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.white.opacity(active ? 1 : 0.5))
            .shadow(color: Theme.crust.opacity(0.8), radius: 2, y: 1)
            .scaleEffect(active ? 1.1 : 1)
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

private struct OverlayButton: View {
    var title: String?
    var systemImage: String?
    let help: String
    /// Tells the grid which hover button the pointer is over (dimming).
    var report: (Bool) -> Void = { _ in }
    let action: () -> Void
    @Environment(\.overlayUnit) private var unit
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(Theme.condensed(unit, weight: .semibold))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: unit, weight: .semibold))
                }
            }
            .modifier(OverlayLabel(active: hovering))
            .padding(.horizontal, unit * 0.3)
            .frame(minWidth: unit * 1.7, minHeight: unit * 1.6)
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
    @Environment(\.overlayUnit) private var unit
    @State private var hovering = false

    var body: some View {
        // Clearly larger than the other buttons: the main control.
        Text("‹|›")
            .font(Theme.condensed(unit * 1.9, weight: .semibold))
            .modifier(OverlayLabel(active: hovering || model.scrub?.thumbId == thumb.id))
            .frame(width: unit * 3.6, height: unit * 2.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help("Scrub (⇧ before, ⌥ after, ⌃ ends)")
            .accessibilityLabel("Scrub")
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
    /// Font size of the hover overlay, from `HoverOverlay.unit(for:)`.
    @Entry var overlayUnit: CGFloat = 15
}
