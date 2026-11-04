import AVFoundation
import AppKit
import FrameSheetCore
import SwiftUI

/// The player view (§9), laid out as MoviePrint's player (App.js and
/// app/components/VideoPlayer.js, MoviePrint v0.2.23, MIT): the video on
/// top, then the frame strip, the timeline bars, the step buttons with the
/// current frame, and the sheet as one horizontal strip below (thumbs, or
/// scene bars at 0.3 pt per frame in cut mode). MoviePrint draws its frame
/// strip as the video area itself and shows the full frame only in its
/// optional HTML5 player; here the native player shows the full frame and
/// the strip sits under it.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet

    static let timelineHeight: CGFloat = 30
    static let controlsHeight: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            let sheetHeight = min(110, max(64, total * 0.16))
            let rest = max(0, total - sheetHeight - Self.timelineHeight - Self.controlsHeight - Theme.space2)
            let stripHeight = min(140, max(48, rest * 0.22))
            VStack(spacing: 0) {
                PlayerVideo(file: file)
                    .frame(height: max(0, rest - stripHeight))
                FrameStrip(file: file)
                    .frame(height: stripHeight)
                    .padding(.top, Theme.space2)
                PlayerTimeline(file: file, sheet: sheet)
                    .frame(height: Self.timelineHeight)
                    .padding(.horizontal, Theme.space4)
                PlayerControls(file: file, sheet: sheet)
                    .frame(height: Self.controlsHeight)
                PlayerSheetStrip(file: file, sheet: sheet)
                    .frame(height: sheetHeight)
                    .background(Theme.mantle)
            }
        }
        .background(Theme.base)
        // Also on appearing: the movie or sheet may have changed while
        // none was shown.
        .onAppear { model.player.currentSheetChanged() }
        .onChange(of: model.currentRef) { model.player.currentSheetChanged() }
    }
}

// MARK: - Video

/// The full frame: AVPlayer's layer while playing (ffmpeg's frames for
/// ffmpeg-routed files, with a label saying so), and over it the exact
/// still of the current frame while paused (decision 25's steps), with the
/// nearest-frame marker when the frame could not be decoded exactly.
private struct PlayerVideo: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile

    var body: some View {
        let player = model.player
        let ratio = player.aspectRatioInv(file)
        GeometryReader { proxy in
            let fit = Self.fitted(proxy.size, ratio: ratio)
            ZStack {
                if player.decoder == .avFoundation {
                    PlayerLayerView(player: player.player)
                        .frame(width: fit.width, height: fit.height)
                        .opacity(player.showsLayer ? 1 : 0)
                }
                if let still = player.coveringStill {
                    Image(decorative: still.image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .overlay {
                            // A faces sheet's thumb at this frame: its faces.
                            if let sheet = model.currentSheet, model.showsFaceRectangles(sheet),
                               let thumb = sheet.thumbs.first(where: { $0.frameNumber == still.shown && !$0.faces.isEmpty }) {
                                FaceRectangles(faces: sheet.shownFaces(of: thumb))
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if still.requested == player.frame, !still.isExact {
                                NearestFrameMarker(size: fit)
                                    .help(NearestFrameMarker.help(asked: still.requested))
                            }
                        }
                } else if player.showsStill, player.isPlaying {
                    // Playback through leading frames of an open GOP that
                    // AVPlayer cannot show: covered until the keyframe.
                    Theme.crust.frame(width: fit.width, height: fit.height)
                }
                if player.isFFmpegPlaying {
                    PlaybackLayerView(layer: player.playbackLayer)
                        .frame(width: fit.width, height: fit.height)
                        .opacity(player.showsPlaybackFrame ? 1 : 0)
                        .overlay(alignment: .topLeading) {
                            Text("Playback using ffmpeg · no audio")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, Theme.space2)
                                .padding(.vertical, Theme.space1)
                                .background(
                                    Theme.crust.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                                .padding(Theme.space2)
                                .allowsHitTesting(false)
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onGeometryChange(for: CGSize.self) { Self.fitted($0.size, ratio: ratio) } action: { size in
                player.videoSize = size
                player.sizesChanged()
            }
        }
        .background(Theme.crust)
    }

    /// The frame fitted into `size`, aspect kept.
    nonisolated static func fitted(_ size: CGSize, ratio: Double) -> CGSize {
        guard size.width > 0, size.height > 0, ratio > 0 else { return .zero }
        let width = min(size.width, size.height / ratio)
        return CGSize(width: width, height: width * ratio)
    }
}

/// AVPlayer's video layer (AVKit's controls are not used: the player view
/// has its own).
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// The layer ffmpeg playback draws its frames into.
private struct PlaybackLayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> HostedLayerNSView {
        HostedLayerNSView(hosted: layer)
    }

    func updateNSView(_ view: HostedLayerNSView, context: Context) {}
}

private final class HostedLayerNSView: NSView {
    let hosted: CALayer

    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        wantsLayer = true
        hosted.removeFromSuperlayer()
        layer?.addSublayer(hosted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}

private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Frame strip

/// The frame strip (§9, `FrameStripGeometry`): the middle part of each
/// consecutive frame around the current one, the current slice outlined.
/// Slices that show the nearest decodable frame instead carry the marker.
/// While playing it is dimmed and not decoded (AVPlayer holds the decoder).
private struct FrameStrip: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile

    var body: some View {
        let player = model.player
        let generation = player.stripGeneration
        let ratio = player.aspectRatioInv(file)
        GeometryReader { proxy in
            let geometry = player.stripGeometry(file, size: proxy.size)
            Canvas { context, size in
                _ = generation
                let frameWidth = size.height / ratio
                for (index, slice) in geometry.slices.enumerated() where slice.inMovie {
                    let rect = CGRect(x: slice.x, y: 0, width: slice.width, height: size.height)
                    guard let decoded = player.stripFrame(slice.frame) else {
                        context.fill(Path(rect), with: .color(Theme.surface))
                        continue
                    }
                    context.drawLayer { layer in
                        layer.clip(to: Path(rect))
                        layer.draw(
                            Image(decorative: decoded.image, scale: 1),
                            in: CGRect(x: slice.x - slice.cropX, y: 0, width: frameWidth, height: size.height))
                    }
                    if !decoded.isExact, slice.width >= 12 {
                        context.draw(
                            Text(Image(systemName: "arrow.uturn.backward"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.white),
                            at: CGPoint(x: rect.maxX - 7, y: rect.maxY - 8))
                    }
                    if index == geometry.currentIndex {
                        context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(Theme.accent), lineWidth: 2)
                    }
                }
            }
            .opacity(player.isPlaying ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture { location in
                // A click on a slice moves to its frame.
                guard let slice = geometry.slices.first(where: { location.x >= $0.x && location.x < $0.x + $0.width }),
                      slice.inMovie
                else { return }
                player.move(to: slice.frame)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                player.stripSize = size
                player.sizesChanged()
            }
        }
        .help("Frames around the current one; click a slice to go there")
        .accessibilityLabel("Frame strip")
    }
}

// MARK: - Timeline

/// MoviePrint's two timeline bars: the current scene with one bucket per
/// frame, and the whole movie with the sheet's range between its IN and
/// OUT marks, the current scene and the playhead. Click or drag to move.
private struct PlayerTimeline: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet

    var body: some View {
        let player = model.player
        let scene = PlayerNavigation.scene(containing: player.frame, in: player.scenes())
        let sceneIn = scene?.start ?? 0
        let sceneOut = scene.map { $0.start + $0.length - 1 } ?? max(0, file.frameCount - 1)
        let frames = sheet.type == .shot ? sheet.scenes.flatMap { [$0.start, $0.start + $0.length - 1] }
            : model.shownThumbs(of: sheet).map(\.frameNumber)
        let low = frames.min() ?? 0
        let high = frames.max() ?? max(0, file.frameCount - 1)
        GeometryReader { proxy in
            let bar = PlayerTimelineGeometry(
                width: proxy.size.width, frameCount: file.frameCount, sceneIn: sceneIn, sceneOut: sceneOut)
            VStack(spacing: 3) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.surface.opacity(0.6))
                    Rectangle().fill(Theme.accent)
                        .frame(width: bar.sceneFrameWidth)
                        .offset(x: bar.scenePlayheadX(frame: player.frame))
                }
                .frame(height: 11)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    player.move(to: bar.sceneFrame(atX: value.location.x))
                })
                .help("Scene: frames \(sceneIn)–\(sceneOut); click or drag to move")
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.surface.opacity(0.6))
                    let range = bar.range(from: low, to: high)
                    Rectangle().fill(Theme.surfaceHover)
                        .frame(width: range.width)
                        .offset(x: range.x)
                    // IN and OUT marks.
                    Rectangle().fill(Theme.textMuted).frame(width: 2).offset(x: range.x)
                    Rectangle().fill(Theme.textMuted).frame(width: 2).offset(x: range.x + range.width - 2)
                    let current = bar.range(from: sceneIn, to: sceneOut)
                    Rectangle().fill(Theme.accent.opacity(0.35))
                        .frame(width: current.width)
                        .offset(x: current.x)
                    Rectangle().fill(Theme.accent)
                        .frame(width: bar.frameWidth)
                        .offset(x: bar.playheadX(frame: player.frame))
                }
                .frame(height: 11)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    player.move(to: bar.frame(atX: value.location.x))
                })
                .help("Movie: IN \(low), OUT \(high); click or drag to move")
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Controls

/// The step buttons with the edit at the current frame in the middle
/// (§9; MoviePrint's buttons): previous, −100, −10, −1, CUT / MERGE (cut
/// mode) or CHANGE (shot sheets in thumb mode) or CHANGE / ADD BEFORE /
/// ADD AFTER (interval sheets), +1, +10, +100, next. At the left the mode
/// (shot sheets), Play/Pause and the frame number with its timecode; at the
/// right Save frame.
private struct PlayerControls: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet

    var body: some View {
        let player = model.player
        let cut = player.mode == .cut
        let unit = cut ? "cut" : "thumb"
        HStack(spacing: Theme.space2) {
            HStack(spacing: Theme.space1) {
                if sheet.type == .shot {
                    button(cut ? "CUT MODE" : "THUMB MODE", help: "Switch between cut/merge and change-thumb mode (Space)") {
                        player.toggleMode()
                    }
                }
                button(
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                    help: player.isPlaying ? "Pause (P)"
                        : player.decoder == .ffmpeg ? "Play, video only (P)" : "Play (P)"
                ) { player.togglePlayback() }
                .disabled(!player.canPlay)
                FrameLabel(file: file)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.space1) {
                button(systemImage: "backward.end", help: "Previous \(unit) (⇧⌥←)") { player.jump(.previous) }
                button("−100", help: "100 frames back (⌥←)") { player.step(-100) }
                button("−10", help: "10 frames back (←)") { player.step(-10) }
                button("−1", help: "1 frame back (⇧←)") { player.step(-1) }
                editButtons
                button("+1", help: "1 frame forward (⇧→)") { player.step(1) }
                button("+10", help: "10 frames forward (→)") { player.step(10) }
                button("+100", help: "100 frames forward (⌥→)") { player.step(100) }
                button(systemImage: "forward.end", help: "Next \(unit) (⇧⌥→)") { player.jump(.next) }
            }
            .fixedSize()
            HStack(spacing: Theme.space1) {
                button(systemImage: "square.and.arrow.down", help: "Save frame (S)") { model.saveCurrentFrame() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.space4)
    }

    /// The edit at the current frame for the sheet and mode.
    @ViewBuilder private var editButtons: some View {
        let player = model.player
        let blocked = model.isStreamingSheetShown
        switch (sheet.type, player.mode) {
        case (.shot, .cut):
            let merge = model.playerCutAction == .merge
            button(merge ? "MERGE" : "CUT", help: merge ? "Merge scenes at this cut (Return)" : "Cut scene here (Return)") {
                model.cutOrMergeAtPlayerFrame()
            }
            .disabled(blocked || (!merge && player.frame == 0))
        case (.shot, .thumb):
            button("CHANGE", help: "Change the scene's thumb to this frame (Return)") {
                model.playerThumbAction(.change)
            }
            .disabled(blocked)
        case (.interval, _):
            let noSelection = !sheet.thumbs.contains { $0.id == model.selectedThumbId }
            button("ADD BEFORE", help: "Add a thumb at this frame before the selected one (⇧Return)") {
                model.playerThumbAction(.add(.before))
            }
            .disabled(blocked || noSelection)
            button("CHANGE", help: "Change the selected thumb to this frame (Return)") {
                model.playerThumbAction(.change)
            }
            .disabled(blocked || noSelection)
            button("ADD AFTER", help: "Add a thumb at this frame after the selected one (⌥Return)") {
                model.playerThumbAction(.add(.after))
            }
            .disabled(blocked || noSelection)
        case (.faces, _):
            EmptyView()
        }
    }

    private func button(
        _ title: String? = nil, systemImage: String? = nil, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let title {
                Text(title).font(Theme.mono(12, medium: true))
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(PlayerButtonStyle())
        .help(help)
    }
}

/// The current frame and its timecode; "→ shows M" while the still is the
/// nearest decodable frame (decision 25).
private struct FrameLabel: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile

    var body: some View {
        let player = model.player
        let frame = player.frame
        let still = player.still
        HStack(spacing: Theme.space2) {
            // Muted while the still of this frame is being decoded.
            Text(FrameInfoText.text(.frames, frame: frame, fps: file.fps) ?? "")
                .font(Theme.mono(15, medium: true))
                .foregroundStyle(player.isPlaying || still?.requested == frame ? Theme.text : Theme.textMuted)
            Text(Timecode.string(frames: frame, fps: file.fps))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
            if let still, still.requested == frame, !still.isExact, !player.isPlaying {
                Text("→ shows \(FrameInfoText.text(.frames, frame: still.shown, fps: file.fps) ?? "")")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.warning)
                    .help(NearestFrameMarker.help(asked: still.requested) + " (\(model.exactFrameHint))")
            }
        }
        .fixedSize()
        .padding(.horizontal, Theme.space2)
    }
}

/// Text and icon buttons of the player controls: no background at rest,
/// `surfaceHover` under the pointer, `borderControl` while pressed.
private struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerButtonBody(configuration: configuration)
    }
}

private struct PlayerButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.text : Theme.textMuted.opacity(0.5))
            .frame(minWidth: 34, minHeight: 26)
            .padding(.horizontal, 4)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            .onHover { hovering = $0 }
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Theme.borderControl.opacity(0.6) }
        return hovering ? Theme.surfaceHover : Theme.surface.opacity(0.5)
    }
}

// MARK: - Sheet strip

/// The sheet as one horizontal strip: the thumbs in thumb mode, the scene
/// bars in cut mode. The selected thumb or scene is outlined and kept in
/// view; a click selects it and moves the player there, a double-click
/// closes the player view.
private struct PlayerSheetStrip: View {
    @Environment(AppModel.self) private var model
    let file: MovieFile
    let sheet: Sheet

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height - Theme.space2 * 2)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    if model.player.mode == .cut && sheet.type == .shot {
                        sceneBars(height: height)
                    } else {
                        thumbs(height: height)
                    }
                }
                .onAppear {
                    if let id = model.selectedThumbId { reader.scrollTo(id, anchor: .center) }
                }
                .onChange(of: model.selectedThumbId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func thumbs(height: Double) -> some View {
        let width = height / model.player.aspectRatioInv(file)
        return LazyHStack(spacing: PlayerSceneBars.margin) {
            ForEach(model.shownThumbs(of: sheet)) { thumb in
                let selected = model.selectedThumbId == thumb.id
                Group {
                    if let image = model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                .opacity(thumb.hidden ? 0.4 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if let requested = model.nearestFrame(of: thumb) {
                        NearestFrameMarker(size: CGSize(width: width, height: height))
                            .help(NearestFrameMarker.help(asked: requested))
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.accent, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .help("Frame \(thumb.frameNumber) · \(Timecode.string(frames: thumb.frameNumber, fps: file.fps))")
                .onTapGesture { click(thumb.id, frame: thumb.frameNumber) }
                .id(thumb.id)
            }
        }
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, Theme.space2)
    }

    private func sceneBars(height: Double) -> some View {
        let scenes = model.player.scenes()
        let widths = PlayerSceneBars.widths(
            scenes: scenes, minSceneLength: model.library.settings.timelineMinSceneLength,
            selected: model.selectedThumbId, fullWidth: height / model.player.aspectRatioInv(file))
        return LazyHStack(spacing: PlayerSceneBars.margin) {
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                let selected = model.selectedThumbId == scene.id
                let width = widths[index]
                let end = scene.start + max(1, scene.length) - 1
                Group {
                    if selected, let thumb = sheet.thumbs.first(where: { $0.id == scene.id }),
                       let image = model.image(file: file.id, frame: thumb.frameNumber, width: AppModel.thumbWidth) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Self.color(scene)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: min(Theme.radiusSm, width / 2)))
                .opacity(scene.hidden ? 0.4 : 1)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: min(Theme.radiusSm, width / 2))
                            .strokeBorder(Theme.accent, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .help("Frames \(scene.start)–\(end) · \(scene.length) frames")
                .onTapGesture { click(scene.id, frame: scene.start) }
                .id(scene.id)
            }
        }
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, Theme.space2)
    }

    private func click(_ id: UUID, frame: Int) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            model.togglePlayerView()
        } else {
            model.player.select(id, frame: frame)
        }
    }

    static func color(_ scene: FrameSheetCore.Scene) -> Color {
        guard scene.colorRGB.count == 3 else { return Theme.surface }
        return Color(
            .sRGB, red: Double(scene.colorRGB[0]) / 255, green: Double(scene.colorRGB[1]) / 255,
            blue: Double(scene.colorRGB[2]) / 255)
    }
}
