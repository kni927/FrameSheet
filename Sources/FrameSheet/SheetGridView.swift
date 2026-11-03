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
        // Target rows beyond the thumbs' rows preview as empty cells.
        let cellCount = model.gridCellCount(of: sheet)
        // Target rows below the thumbs' rows dim the thumbs past columns × rows.
        let targetCount = sheet.columnCount * model.targetRows(of: sheet)
        GeometryReader { proxy in
            let padding = Self.padding
            let top = padding
            let geometry = Self.geometry(
                file: file, columns: sheet.columnCount, thumbCount: cellCount, settings: settings,
                size: proxy.size, zoom: model.zoom)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    // The print as it is saved; the interaction layer and
                    // the placeholders lie over it.
                    PrintView(file: file, thumbs: thumbs, geometry: geometry, settings: settings) { thumb in
                        model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth)
                    }
                    ForEach(Array(thumbs.enumerated()), id: \.element.id) { index, thumb in
                        let frame = geometry.thumbFrame(at: index)
                        ThumbView(
                            file: file, sheet: sheet, thumb: thumb, size: frame.size,
                            cornerRadius: geometry.borderRadius, dimmed: dimmed.contains(thumb.id) || index >= targetCount,
                            onHoverButton: { button in
                                hoverButton = button.map { (thumb.id, $0) }
                            })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    ForEach(thumbs.count..<max(thumbs.count, cellCount), id: \.self) { index in
                        let frame = geometry.thumbFrame(at: index)
                        RoundedRectangle(cornerRadius: geometry.borderRadius)
                            .fill(Theme.surface)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .allowsHitTesting(false)
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

    /// Space around the print on every side.
    static let padding = Theme.space4

    /// Layout of the print in a grid area of `size` (also used by the
    /// toolbar's Fit height and Fit width).
    static func geometry(
        file: MovieFile, columns: Int, thumbCount: Int, settings: FrameSheetCore.Settings, size: CGSize, zoom: Double
    ) -> GridGeometry {
        GridGeometry(.init(
            file: file, columnCount: columns, thumbCount: thumbCount, settings: settings,
            containerWidth: max(1, size.width - padding * 2 - GridGeometry.minPrintWidthMargin),
            containerHeight: max(1, size.height - padding * 2), zoom: zoom))
    }
}

/// The interaction layer of one thumb over the print: tooltip, dimming,
/// hover buttons, selection and drop target, selection by click and drag
/// to reorder. The thumb itself is drawn by `PrintView`.
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
        Color.clear
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Under the hover buttons: a tooltip on the whole thumb would replace
        // their own tooltips.
        .help("Frame \(thumb.frameNumber) · \(Timecode.string(frames: thumb.frameNumber, fps: file.fps))")
        .overlay {
            if dimmed {
                RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.crust.opacity(0.65))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Window only, not in the saved print: the thumb shows the
            // nearest decodable frame (decision 11), labeled by that frame.
            if let requested = model.nearestFrame(of: thumb), !showOverlay {
                NearestFrameMarker(size: size)
                    .help("Nearest decodable frame (frame \(requested) asked for; \(model.exactFrameHint))")
            }
        }
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
        .draggable(thumb.id.uuidString) {
            // The thumb as the drag image; the cell itself is transparent.
            if let image = model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
        .dropDestination(for: String.self) { items, location in
            // The left half drops before this thumb, the right half after.
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.moveThumb(dragged, onto: thumb.id, after: location.x > size.width / 2)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}

/// The small badge on a thumb that shows the nearest decodable frame
/// instead of the one it asked for.
private struct NearestFrameMarker: View {
    let size: CGSize

    var body: some View {
        let unit = min(max(size.height * 0.09, 9), 16)
        Image(systemName: "arrow.uturn.backward")
            .font(.system(size: unit * 0.7, weight: .bold))
            .foregroundStyle(Theme.crust)
            .frame(width: unit * 1.4, height: unit * 1.4)
            .background(Circle().fill(Theme.warning))
            .padding(unit * 0.4)
            .contentShape(Rectangle())
            .accessibilityLabel("Nearest decodable frame")
    }
}

/// Buttons over a hovered thumb (§7): IN and OUT on top, insert before and
/// after at the sides, the scrub handle in the middle, EXPAND, HIDE/SHOW and
/// SAVE (thumb) at the bottom. Option-click on IN/OUT hides all before/after.
/// Drawn as in MoviePrint: faint white over the thumb, solid white under the
/// pointer, with a dark shadow instead of a backdrop (owner, 2026-11-03).
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
            // MoviePrint's arrangement: EXPAND at the left, HIDE in the
            // middle, SAVE at the right.
            ZStack {
                HStack {
                    OverlayButton(title: "EXPAND", help: "Expand to 16 thumbs", report: { onHoverButton($0 ? .expand : nil) }) {
                        model.expand(thumb.id)
                    }
                    Spacer()
                    OverlayButton(title: "SAVE", help: "Save thumb (full size)") {
                        model.saveThumb(thumb.id)
                    }
                }
                OverlayButton(
                    title: thumb.hidden ? "SHOW" : "HIDE", help: thumb.hidden ? "Show thumb" : "Hide thumb",
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
