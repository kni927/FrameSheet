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
                    PrintView(
                        file: file, thumbs: thumbs, layout: .grid(geometry), settings: settings,
                        faceRectangles: model.showsFaceRectangles(sheet), faceFilter: sheet.faceFilter
                    ) { thumb in
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
                    // Window only: where Insert before / after puts the new
                    // thumb, while the pointer is over the button.
                    if let marker = insertMarker(geometry: geometry, thumbs: thumbs) {
                        RoundedRectangle(cornerRadius: min(marker.width / 2, 2))
                            .fill(Theme.accent)
                            .frame(width: marker.width, height: marker.height)
                            .offset(x: marker.minX, y: marker.minY)
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

    /// The insert marker for the hover button under the pointer, if it is
    /// Insert before or after.
    private func insertMarker(geometry: GridGeometry, thumbs: [Thumb]) -> CGRect? {
        guard let hoverButton, let index = thumbs.firstIndex(where: { $0.id == hoverButton.thumb }) else { return nil }
        switch hoverButton.button {
        case .insertBefore: return geometry.insertMarker(.before, at: index, count: thumbs.count)
        case .insertAfter: return geometry.insertMarker(.after, at: index, count: thumbs.count)
        default: return nil
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

    /// Timeline layout of a sheet's scenes in an area of `size` (also used
    /// by Fit height and Fit width).
    static func timelineGeometry(
        file: MovieFile, sheet: Sheet, scenes: [FrameSheetCore.Scene], settings: FrameSheetCore.Settings, size: CGSize,
        zoom: Double, expandedIndex: Int?
    ) -> TimelineGeometry {
        TimelineGeometry(.init(
            file: file, sheet: sheet, scenes: scenes, settings: settings,
            containerWidth: max(1, size.width - padding * 2), containerHeight: max(1, size.height - padding * 2),
            zoom: zoom, expandedIndex: expandedIndex))
    }
}

/// Timeline view of a sheet (§6, §7, §10): the print's scene boxes laid
/// out by `TimelineGeometry`, with a layer that selects a scene on click
/// (the selected scene widens to full aspect width; a second click on it
/// deselects), names its frames in a tooltip, and shows the scene's hover
/// overlay.
struct TimelineSheetView: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    /// The hover button under the pointer, for dimming the scenes it affects.
    @State private var hoverButton: (scene: UUID, button: HoverButton)?

    var body: some View {
        let settings = model.library.settings
        let scenes = model.timelineScenes(of: sheet)
        let dimmed = hoverButton.map { Sheet.affected($0.button, of: $0.scene, in: scenes.map(\.id)) } ?? []
        let padding = SheetGridView.padding
        GeometryReader { proxy in
            let geometry = model.timelineGeometry(file: file, sheet: sheet, size: proxy.size)
            let size = geometry.contentSize
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    PrintView(
                        file: file, thumbs: sheet.thumbs, layout: .timeline(geometry, scenes: scenes),
                        settings: settings
                    ) { thumb in
                        model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth)
                    }
                    ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                        let frame = geometry.sceneFrames[index]
                        SceneCell(
                            file: file, sheet: sheet, scene: scene, size: frame.size,
                            cornerRadius: min(geometry.borderRadius, frame.width / 2),
                            dimmed: dimmed.contains(scene.id),
                            onHoverButton: { button in
                                hoverButton = button.map { (scene.id, $0) }
                            })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: size.width, height: size.height)
                .padding(padding)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }
}

/// The interaction layer of one timeline scene: tooltip, hover highlight
/// and overlay, dimming, selection outline, click to select or deselect.
private struct SceneCell: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet
    let scene: FrameSheetCore.Scene
    let size: CGSize
    let cornerRadius: Double
    let dimmed: Bool
    let onHoverButton: (HoverButton?) -> Void
    @State private var hovering = false

    var body: some View {
        let selected = model.selectedThumbId == scene.id
        let scrubbing = model.scrub?.thumbId == scene.id
        let showOverlay = (hovering || scrubbing) && size.width >= ThumbView.minOverlayWidth
            && (model.scrub == nil || scrubbing)
        let end = scene.start + max(1, scene.length) - 1
        Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            // Under the overlay, so its buttons keep their own tooltips.
            .help("Frames \(scene.start)–\(end) · \(scene.length) frames · \(Timecode.string(frames: scene.start, fps: file.fps))")
            .overlay {
                if dimmed {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.crust.opacity(0.65))
                } else if hovering && !selected {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.crust.opacity(0.2))
                }
            }
            .overlay {
                if showOverlay {
                    SceneHoverOverlay(sheet: sheet, scene: scene, size: size, onHoverButton: onHoverButton)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
            .onHover { inside in
                hovering = inside
                if !inside { onHoverButton(nil) }
            }
            .onTapGesture {
                // A double-click opens (or closes) the player view at the
                // scene (§7); its first click selected it.
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    model.doubleClicked(scene.id)
                } else {
                    model.selectedThumbId = selected ? nil : scene.id
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scene, frames \(scene.start) to \(end)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Buttons over a hovered timeline scene, in MoviePrint's arrangement
/// (`Scene.js`): EXPAND at the top left and HIDE/SHOW at the top center;
/// Jump to cut at the start and end at the middle of the sides (shot
/// sheets), the scrub handle between them (commented out in MoviePrint,
/// asked for by §7); Hide all before and after at the bottom corners, which
/// MoviePrint labels IN and OUT and leaves out on a hidden scene. Drawn as
/// the grid's overlay: faint white labels sized from the scene box.
private struct SceneHoverOverlay: View {
    @Environment(AppModel.self) private var model
    let sheet: Sheet
    let scene: FrameSheetCore.Scene
    let size: CGSize
    let onHoverButton: (HoverButton?) -> Void

    var body: some View {
        let isShot = sheet.type == .shot
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    OverlayButton(title: "EXPAND", help: "Expand to 16 thumbs", report: { onHoverButton($0 ? .expand : nil) }) {
                        model.expand(scene.id)
                    }
                    Spacer()
                }
                OverlayButton(
                    title: scene.hidden ? "SHOW" : "HIDE", help: scene.hidden ? "Show scene" : "Hide scene",
                    report: { onHoverButton($0 ? .hide : nil) }
                ) {
                    onHoverButton(nil)
                    model.toggleHidden(scene.id)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if isShot { JumpToCutButton(neighbor: .previous, scene: scene.id) }
                Spacer()
                ScrubHandle(thumbId: scene.id, sceneLimited: isShot)
                Spacer()
                if isShot { JumpToCutButton(neighbor: .next, scene: scene.id) }
            }
            Spacer(minLength: 0)
            HStack {
                if !scene.hidden {
                    OverlayButton(title: "◀ HIDE", help: "Hide all before", report: { onHoverButton($0 ? .inPoint : nil) }) {
                        onHoverButton(nil)
                        model.hideAll(.before, of: scene.id)
                    }
                    Spacer()
                    OverlayButton(title: "HIDE ▶", help: "Hide all after", report: { onHoverButton($0 ? .outPoint : nil) }) {
                        onHoverButton(nil)
                        model.hideAll(.after, of: scene.id)
                    }
                }
            }
        }
        .padding(HoverOverlay.unit(for: size) * 0.3)
        .environment(\.overlayUnit, HoverOverlay.unit(for: size))
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
        .overlay {
            if showOverlay {
                HoverOverlay(file: file, sheet: sheet, thumb: thumb, size: size, onHoverButton: onHoverButton)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Window only, not in the saved print: the thumb shows the
            // nearest decodable frame (decision 11), labeled by that frame.
            // The bottom-right corner holds no hover button, so the marker
            // stays while hovering and its tooltip can show.
            if let requested = model.nearestFrame(of: thumb) {
                NearestFrameMarker(size: size)
                    .help(NearestFrameMarker.help(asked: requested))
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
        .onTapGesture {
            // Double-click toggles the player view (§7).
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.doubleClicked(thumb.id)
            } else {
                model.selectedThumbId = thumb.id
            }
        }
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

/// The small mark on a thumb that shows the nearest decodable frame
/// instead of the one it asked for: drawn as a label of the hover overlay's
/// bottom row (same font size, baseline and side margin as EXPAND and HIDE),
/// in the bottom-right corner, faint white at rest and solid white under the
/// pointer (owner, 2026-11-03). The scrub overlay marks its frames with it
/// too.
struct NearestFrameMarker: View {
    let size: CGSize
    @State private var hovering = false

    static func help(asked requested: Int) -> String {
        "Nearest decodable frame (asked \(requested.formatted(.number.locale(Locale(identifier: "en_US")))))"
    }

    var body: some View {
        let unit = HoverOverlay.unit(for: size)
        // A symbol inside Text sits on the text baseline, as the labels do;
        // the frame and paddings are OverlayButton's and HoverOverlay's.
        Text(Image(systemName: "arrow.uturn.backward"))
            .font(Theme.condensed(unit, weight: .semibold))
            .modifier(OverlayLabel(active: hovering))
            .padding(.horizontal, unit * 0.3)
            .frame(minWidth: unit * 1.7, minHeight: unit * 1.6, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(unit * 0.3)
            .accessibilityLabel("Nearest decodable frame")
    }
}

/// Buttons over a hovered thumb (§7): IN, SAVE (thumb) and OUT on top,
/// insert before and after at the sides, the scrub handle in the middle,
/// EXPAND and HIDE/SHOW at the bottom, whose right corner is left free for
/// the nearest-frame marker. Option-click on IN/OUT hides all before/after.
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
            ZStack {
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
                // Between IN and OUT, so the bottom-right corner stays free
                // for the nearest-frame marker (owner, 2026-11-03).
                OverlayButton(title: "SAVE", help: "Save thumb (full size)") {
                    model.saveThumb(thumb.id)
                }
            }
            Spacer(minLength: 0)
            // Shot sheets keep one thumb per scene: Jump to cut instead of
            // insert (§7), and the scrub stays inside the scene.
            HStack {
                if sheet.type == .shot {
                    JumpToCutButton(neighbor: .previous, scene: thumb.id)
                } else {
                    OverlayButton(systemImage: "plus", help: "Insert before", report: { onHoverButton($0 ? .insertBefore : nil) }) {
                        model.insertThumb(.before, relativeTo: thumb.id)
                    }
                }
                Spacer()
                ScrubHandle(thumbId: thumb.id, sceneLimited: sheet.type == .shot)
                Spacer()
                if sheet.type == .shot {
                    JumpToCutButton(neighbor: .next, scene: thumb.id)
                } else {
                    OverlayButton(systemImage: "plus", help: "Insert after", report: { onHoverButton($0 ? .insertAfter : nil) }) {
                        model.insertThumb(.after, relativeTo: thumb.id)
                    }
                }
            }
            Spacer(minLength: 0)
            // MoviePrint's arrangement: EXPAND at the left, HIDE in the
            // middle (MoviePrint's SAVE at the right moved to the top).
            ZStack {
                HStack {
                    OverlayButton(title: "EXPAND", help: "Expand to 16 thumbs", report: { onHoverButton($0 ? .expand : nil) }) {
                        model.expand(thumb.id)
                    }
                    Spacer()
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

/// Jump to cut at the start or end of a shot sheet's scene (§7, MoviePrint's
/// `||` buttons at the scene's sides).
private struct JumpToCutButton: View {
    @Environment(AppModel.self) private var model
    let neighbor: SceneNeighbor
    let scene: UUID

    var body: some View {
        OverlayButton(
            systemImage: neighbor == .previous ? "arrow.left.to.line" : "arrow.right.to.line",
            help: neighbor == .previous ? "Jump to cut at start" : "Jump to cut at end"
        ) {
            model.jumpToCut(neighbor, of: scene)
        }
    }
}

/// Drag it to scrub (§7). The drag reports its location in the main area's
/// coordinate space, where the scrub overlay is drawn.
private struct ScrubHandle: View {
    @Environment(AppModel.self) private var model
    let thumbId: UUID
    /// A shot sheet's scrub: inside the scene, always change.
    var sceneLimited = false
    @Environment(\.overlayUnit) private var unit
    @State private var hovering = false

    var body: some View {
        // Clearly larger than the other buttons: the main control.
        Text("‹|›")
            .font(Theme.condensed(unit * 1.9, weight: .semibold))
            .modifier(OverlayLabel(active: hovering || model.scrub?.thumbId == thumbId))
            .frame(width: unit * 3.6, height: unit * 2.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(sceneLimited ? "Scrub inside the scene" : "Scrub (⇧ before, ⌥ after, ⌃ ends)")
            .accessibilityLabel("Scrub")
            .highPriorityGesture(
                // Starts on mouse-down, so the thumb's own drag (reorder)
                // cannot take it; a quick click leaves the scrub open.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(MainArea.space))
                    .onChanged { value in
                        let modifiers = ScrubModifiers(NSEvent.modifierFlags)
                        if model.scrub == nil {
                            model.beginScrub(
                                thumbId, keyboard: false, modifiers: modifiers, x: value.location.x,
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
