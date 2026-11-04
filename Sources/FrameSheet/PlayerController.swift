import AVFoundation
import AppKit
import FrameSheetCore
import Observation

/// One decoded image of the player: the frame asked for and the frame it
/// shows (another one when it could not be decoded exactly, decision 25).
struct PlayerFrame {
    var image: CGImage
    var requested: Int
    var shown: Int

    var isExact: Bool { requested == shown }
}

/// The player view's state (§9): the current frame, the cut or thumb mode,
/// AVPlayer playback, the exact still shown while paused and the frame
/// strip's decoded slices.
///
/// Decoder sessions (KNOWN_ISSUES 4): AVPlayer decodes in its own session,
/// outside the DecodeGate. So playback takes the DecodeGate when it starts
/// and gives it back when it pauses: while AVPlayer plays, no thumb, still,
/// frame-strip or scan decode runs beside it, and a scan or batch that holds
/// the gate makes Play wait until it lets go. A shot scan pauses playback
/// when it starts. While paused, the player item stays but is not seeked or
/// played, so it does not decode; still and strip frames are decoded through
/// the gate. Leaving the player view (or another movie) drops the item.
///
/// ffmpeg-routed files play video only, from one ffmpeg rawvideo pipe at
/// the video area's pixel width (`FFmpegBackend.playbackSource`), paced in
/// real time by `PlaybackLoop` and drawn into `playbackLayer`. It holds the
/// DecodeGate as AVPlayer does; pausing stops ffmpeg and waits for it to
/// exit before the still and the strip decode again, so no two decoder
/// sessions overlap. The last frame shown (named by its timestamp, so
/// exact) becomes the still.
@MainActor @Observable
final class PlayerController {
    enum Playback: Equatable {
        case paused
        /// Waiting for the DecodeGate or the first seek.
        case starting
        case playing
    }

    @ObservationIgnored weak var model: AppModel?

    /// The window shows the player view.
    private(set) var isShown = false
    /// The current frame.
    private(set) var frame = 0
    private(set) var mode: PlayerMode = .thumb
    private(set) var playback: Playback = .paused
    /// The decoder of the movie shown; nil until its backend is open.
    private(set) var decoder: DecoderKind?
    /// The exact still of the current frame while paused (or the frame it
    /// could be decoded as, with `shown` naming it).
    private(set) var still: PlayerFrame?
    /// While playing: the first frame AVPlayer's own image is shown from.
    /// Playback that starts on a leading frame of an open GOP keeps the still
    /// until the GOP's keyframe (see `AVFoundationBackend.firstPlayableFrame`).
    private(set) var playableFrom = 0
    /// The frame playback started (or last seeked) at.
    private(set) var playStart = 0
    /// The frame AVPlayer's paused image shows; nil without one.
    private(set) var layerFrame: Int?
    /// Bumped when strip slices land in the cache, so the strip redraws.
    private(set) var stripGeneration = 0

    /// Size of the video area and the frame strip on screen (points).
    @ObservationIgnored var videoSize: CGSize = .zero
    @ObservationIgnored var stripSize: CGSize = .zero

    let player = AVPlayer()
    /// The frames of ffmpeg playback.
    let playbackLayer = CALayer()
    /// ffmpeg playback has shown a frame (its layer covers the still).
    private(set) var showsPlaybackFrame = false
    @ObservationIgnored private var ffmpegSource: FFmpegPlaybackSource?
    @ObservationIgnored private var ffmpegTask: Task<Void, Never>?
    /// The last ffmpeg stop, which the next decode waits for.
    @ObservationIgnored private var ffmpegStop: Task<Void, Never>?
    @ObservationIgnored private var ffmpegLastFrame: PlaybackFrame?
    /// The pixel width ffmpeg playback decodes at (the still's width).
    @ObservationIgnored private var ffmpegWidth = 0
    @ObservationIgnored private var fileId: UUID?
    @ObservationIgnored private var itemURL: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var holdsGate = false
    @ObservationIgnored private var decodeTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// Counts Play presses, so a start that waited for the gate knows it is
    /// still wanted.
    @ObservationIgnored private var playToken = 0
    /// Strip slices by frame, for `stripCacheKey`'s movie and width.
    @ObservationIgnored private var stripFrames: [Int: PlayerFrame] = [:]
    @ObservationIgnored private var stripCacheKey: (file: UUID, width: Int)?
    /// Recent stills by frame, at `stillCacheKey`'s width.
    @ObservationIgnored private var stills: [(frame: Int, image: PlayerFrame)] = []
    @ObservationIgnored private var stillCacheKey: (file: UUID, width: Int)?
    /// The sidebars before the player view hid them.
    @ObservationIgnored private var sidebars: (movieList: Bool, settings: Bool)?

    static let stripCacheLimit = 400
    static let stillCacheLimit = 8
    /// A short wait before decoding, so held arrow keys decode where they stop.
    static let decodeDelay: Duration = .milliseconds(15)

    init() {
        player.actionAtItemEnd = .pause
        playbackLayer.contentsGravity = .resizeAspect
    }

    // MARK: - Showing

    private var file: MovieFile? {
        guard let model, let id = fileId else { return nil }
        return model.library.file(id)
    }

    /// Opens the player view at the selected thumb's frame (or the sheet's
    /// first thumb), in cut mode for a shot sheet in timeline view, else in
    /// thumb mode; the sidebars are hidden while it is open (MoviePrint's
    /// `onViewToggle`) and come back when it closes.
    func show() {
        guard let model, let file = model.currentFile, let sheet = model.currentSheet else { return }
        model.cancelScrub()
        isShown = true
        mode = sheet.type == .shot && sheet.view == .timeline ? .cut : .thumb
        sidebars = (model.showMovieList, model.showSettings)
        model.showMovieList = false
        model.showSettings = false
        let thumbs = model.shownThumbs(of: sheet)
        let start = thumbs.first { $0.id == model.selectedThumbId }?.frameNumber ?? thumbs.first?.frameNumber ?? 0
        open(file, at: start)
    }

    func hide() {
        guard isShown else { return }
        stopPlayback(dropItem: true)
        decodeTask?.cancel()
        isShown = false
        if let model, let sidebars {
            model.showMovieList = sidebars.movieList
            model.showSettings = sidebars.settings
        }
        sidebars = nil
    }

    /// The movie or sheet shown changed (selection, undo): a new movie starts
    /// over; the same movie keeps the frame, inside it.
    func currentSheetChanged() {
        guard isShown, let model else { return }
        guard let file = model.currentFile, model.currentSheet != nil else {
            hide()
            return
        }
        if file.id != fileId {
            open(file, at: 0)
        } else {
            if model.currentSheet?.type != .shot { mode = .thumb }
            move(to: frame, followSelection: false)
        }
    }

    private func open(_ file: MovieFile, at start: Int) {
        if fileId != file.id {
            stopPlayback(dropItem: true)
            fileId = file.id
            decoder = nil
            still = nil
            stripFrames.removeAll()
            stripCacheKey = nil
            stills.removeAll()
            stillCacheKey = nil
        }
        frame = PlayerNavigation.clamp(start, frameCount: file.frameCount)
        Task {
            guard let model, let backend = try? await model.backend(for: file), fileId == file.id else { return }
            decoder = backend.kind
        }
        scheduleDecodes()
    }

    /// Space on a shot sheet: cut/merge mode ↔ change-thumb mode.
    func toggleMode() {
        guard model?.currentSheet?.type == .shot else { return }
        mode = mode.toggled
        scheduleDecodes()
    }

    // MARK: - Moving

    /// The scenes stepping and the selection follow, and the cuts.
    func scenes() -> [FrameSheetCore.Scene] {
        guard let model, let sheet = model.currentSheet else { return [] }
        return PlayerNavigation.scenes(of: sheet, includeHidden: model.library.settings.showHiddenThumbs)
    }

    /// The cuts the frame strip leaves a wider gap at: the first frames of
    /// a shot sheet's scenes after the first.
    func cuts() -> Set<Int> {
        guard model?.currentSheet?.type == .shot else { return [] }
        return Set(scenes().dropFirst().map(\.start))
    }

    /// Moves to `target` (kept inside the movie). With `followSelection` the
    /// selection moves to the scene or thumb at the frame, as MoviePrint's
    /// player does while stepping. While playing, the player seeks there and
    /// plays on; while paused, the still and the strip decode.
    func move(to target: Int, followSelection: Bool = true) {
        guard let model, let file else { return }
        frame = PlayerNavigation.clamp(target, frameCount: file.frameCount)
        if followSelection, let id = PlayerNavigation.selection(at: frame, scenes: scenes()),
           model.selectedThumbId != id {
            model.selectedThumbId = id
        }
        switch playback {
        case .playing where decoder == .ffmpeg:
            restartFFmpeg(at: frame)
        case .playing:
            if let backend = currentAVBackend {
                playableFrom = frame
                playStart = frame
                player.seek(to: playbackTime(of: frame, backend), toleranceBefore: .zero, toleranceAfter: .zero)
                Task {
                    let first = await backend.firstPlayableFrame(from: frame)
                    if playback == .playing { playableFrom = first }
                }
            }
        case .starting:
            break
        case .paused:
            scheduleDecodes()
        }
    }

    /// ←/→ and the step buttons.
    func step(_ delta: Int) {
        move(to: frame + delta)
    }

    /// ⇧⌥←/→ and the previous/next buttons: the previous or next cut in cut
    /// mode, the previous or next thumb in thumb mode.
    func jump(_ direction: SceneNeighbor) {
        guard let model, let file, let sheet = model.currentSheet else { return }
        switch mode {
        case .cut:
            guard let target = PlayerNavigation.cutJump(
                direction, from: frame, scenes: scenes(), frameCount: file.frameCount)
            else { return }
            if let scene = target.scene { model.selectedThumbId = scene }
            move(to: target.frame)
        case .thumb:
            guard let target = PlayerNavigation.thumbJump(
                direction, from: frame, selected: model.selectedThumbId, sheetType: sheet.type,
                thumbs: model.shownThumbs(of: sheet), scenes: scenes(), frameCount: file.frameCount)
            else { return }
            model.selectedThumbId = target.thumb
            move(to: target.frame, followSelection: sheet.type != .faces)
        }
    }

    /// A click on a thumb or scene of the strip below: selects it and moves
    /// there (MoviePrint's `onSelectThumbMethod` with the frame).
    func select(_ id: UUID, frame target: Int) {
        model?.selectedThumbId = id
        move(to: target, followSelection: false)
    }

    // MARK: - Playback

    private var currentAVBackend: AVFoundationBackend? {
        guard let model, let file else { return nil }
        return model.openBackend(file.id) as? AVFoundationBackend
    }

    /// AVPlayer plays files AVFoundation decodes, with audio; ffmpeg-routed
    /// files play video only through an ffmpeg pipe.
    var canPlay: Bool { decoder == .avFoundation || decoder == .ffmpeg }

    /// ffmpeg playback runs (the video area says so).
    var isFFmpegPlaying: Bool { playback != .paused && decoder == .ffmpeg }

    var isPlaying: Bool { playback != .paused }

    /// The still covers AVPlayer's image while paused, while playback
    /// starts, and while it plays through leading frames it cannot show;
    /// ffmpeg playback's until its first frame is drawn.
    var showsStill: Bool {
        guard playback == .playing else { return true }
        return decoder == .ffmpeg ? !showsPlaybackFrame : frame < playableFrom
    }

    /// AVPlayer's image is shown while playing, and while paused only on
    /// the frame it paused at (stepping does not seek it).
    var showsLayer: Bool { playback != .paused || layerFrame == frame }

    /// The still to draw over AVPlayer's image: while paused the current
    /// still (the previous frame's until the new one is decoded); while
    /// playing only the still of the frame playback started at. Nil while
    /// playing through leading frames without it: the view covers AVPlayer's
    /// image instead.
    var coveringStill: PlayerFrame? {
        guard showsStill, let still else { return nil }
        return playback == .paused || still.requested == playStart ? still : nil
    }

    func togglePlayback() {
        if playback == .paused { play() } else { pause() }
    }

    /// The middle of the frame's display interval, in item time.
    private func playbackTime(of frame: Int, _ backend: AVFoundationBackend) -> CMTime {
        let fps = backend.info.fps > 0 ? backend.info.fps : 25
        return CMTime(seconds: backend.startTime + (Double(frame) + 0.5) / fps, preferredTimescale: 600_000)
    }

    func play() {
        if decoder == .ffmpeg {
            playFFmpeg()
            return
        }
        guard playback == .paused, canPlay, let file, let backend = currentAVBackend else { return }
        // No still or strip decode while AVPlayer decodes.
        decodeTask?.cancel()
        decodeTask = nil
        playback = .starting
        playToken += 1
        let token = playToken
        let start = frame
        playStart = start
        playableFrom = start
        Task {
            await DecoderSessionGate.acquire()
            // Paused, closed or started again while waiting: let go.
            var current: Bool { playToken == token && playback == .starting && fileId == file.id }
            guard current else {
                await DecoderSessionGate.release()
                return
            }
            if itemURL != file.url {
                player.replaceCurrentItem(with: AVPlayerItem(url: file.url))
                itemURL = file.url
            }
            playableFrom = await backend.firstPlayableFrame(from: start)
            _ = await player.seek(to: playbackTime(of: start, backend), toleranceBefore: .zero, toleranceAfter: .zero)
            guard current else {
                await DecoderSessionGate.release()
                if playback == .paused { scheduleDecodes() }
                return
            }
            holdsGate = true
            observeTime(backend)
            player.play()
            playback = .playing
        }
    }

    /// Pauses on the frame AVPlayer shows, then decodes that frame exactly.
    /// ffmpeg playback stops on the last frame it showed.
    func pause() {
        switch playback {
        case .paused:
            return
        case .starting where decoder == .ffmpeg:
            stopFFmpeg()
            scheduleDecodes()
        case .starting:
            // The start task gives the gate back when it sees this.
            playback = .paused
        case .playing where decoder == .ffmpeg:
            stopFFmpeg()
            scheduleDecodes()
        case .playing:
            stopPlayback(dropItem: false)
            scheduleDecodes()
        }
    }

    /// Stops playing at the frame shown and gives the gate back; drops the
    /// player item too with `dropItem`, so its decoder session goes.
    private func stopPlayback(dropItem: Bool) {
        if ffmpegTask != nil || ffmpegSource != nil {
            stopFFmpeg()
            return
        }
        let wasPlaying = playback == .playing
        playback = .paused
        if wasPlaying {
            player.pause()
            if let backend = currentAVBackend, let file {
                frame = PlayerNavigation.frame(
                    atSeconds: player.currentTime().seconds, startTime: backend.startTime, fps: backend.info.fps,
                    frameCount: file.frameCount)
            }
            // AVPlayer's paused image shows until the exact still is decoded,
            // rather than the still of the frame playback started at.
            layerFrame = frame
            if still?.requested != frame { still = nil }
        }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if dropItem {
            player.replaceCurrentItem(with: nil)
            itemURL = nil
            layerFrame = nil
        }
        releaseGate()
    }

    private func releaseGate() {
        guard holdsGate else { return }
        holdsGate = false
        Task { await DecoderSessionGate.release() }
    }

    private func observeTime(_ backend: AVFoundationBackend) {
        let fps = backend.info.fps > 0 ? backend.info.fps : 25
        let interval = CMTime(seconds: max(1 / fps, 1.0 / 30), preferredTimescale: 600_000)
        let startTime = backend.startTime
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(seconds: time.seconds, startTime: startTime, fps: fps)
            }
        }
        // The item pauses itself at the end; pause there too.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    private func tick(seconds: Double, startTime: Double, fps: Double) {
        guard playback == .playing, let model, let file else { return }
        frame = PlayerNavigation.frame(atSeconds: seconds, startTime: startTime, fps: fps, frameCount: file.frameCount)
        if let id = PlayerNavigation.selection(at: frame, scenes: scenes()), model.selectedThumbId != id {
            model.selectedThumbId = id
        }
    }

    // MARK: - ffmpeg playback (video only)

    /// Starts ffmpeg playback at the current frame once the DecodeGate is
    /// free (after the last stop has exited).
    private func playFFmpeg() {
        guard playback == .paused, isShown, let model, let file, videoSize.width > 0,
              let backend = model.openBackend(file.id) as? FFmpegBackend
        else { return }
        decodeTask?.cancel()
        decodeTask = nil
        playback = .starting
        playToken += 1
        let token = playToken
        let start = frame
        playStart = start
        playableFrom = start
        let width = stillWidth(file)
        let previousStop = ffmpegStop
        Task {
            await previousStop?.value
            await DecoderSessionGate.acquire()
            guard playToken == token, playback == .starting, fileId == file.id else {
                await DecoderSessionGate.release()
                if playback == .paused { scheduleDecodes() }
                return
            }
            holdsGate = true
            startFFmpeg(backend, at: start, width: width)
        }
    }

    /// One pipe from `start`, shown in real time until it ends (the movie's
    /// end pauses there) or is stopped. Callers hold the gate.
    private func startFFmpeg(_ backend: FFmpegBackend, at start: Int, width: Int) {
        let source = backend.playbackSource(from: start, maxWidth: width)
        do {
            try source.start()
        } catch {
            model?.toast = "ffmpeg playback could not start: \(error.localizedDescription)"
            stopFFmpeg()
            scheduleDecodes()
            return
        }
        ffmpegSource = source
        ffmpegWidth = width
        playback = .playing
        let fps = backend.info.fps
        ffmpegTask = Task {
            _ = try? await PlaybackLoop.run(
                fps: fps, clock: ContinuousPlaybackClock(), next: { try await source.next() }
            ) { [weak self] frame in
                self?.showPlaybackFrame(frame)
            }
            // The end of the stream, not a stop or a restart: pause there.
            guard !Task.isCancelled, ffmpegSource === source else { return }
            pause()
        }
    }

    private func showPlaybackFrame(_ shown: PlaybackFrame) {
        guard playback == .playing, let model else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playbackLayer.contents = shown.image
        CATransaction.commit()
        ffmpegLastFrame = shown
        if !showsPlaybackFrame { showsPlaybackFrame = true }
        frame = shown.frameNumber
        if let id = PlayerNavigation.selection(at: frame, scenes: scenes()), model.selectedThumbId != id {
            model.selectedThumbId = id
        }
    }

    /// A move while ffmpeg plays: the pipe stops and a new one starts at
    /// `target` once the old one has exited; the gate stays held.
    private func restartFFmpeg(at target: Int) {
        guard let model, let file, let backend = model.openBackend(file.id) as? FFmpegBackend else { return }
        let task = ffmpegTask
        let source = ffmpegSource
        ffmpegTask = nil
        ffmpegSource = nil
        ffmpegLastFrame = nil
        task?.cancel()
        playStart = target
        playToken += 1
        let token = playToken
        let width = ffmpegWidth
        let previous = ffmpegStop
        let stop = Task {
            await previous?.value
            await task?.value
            await source?.close()
        }
        ffmpegStop = stop
        Task {
            await stop.value
            guard playToken == token, playback == .playing, fileId == file.id else { return }
            startFFmpeg(backend, at: target, width: width)
        }
    }

    /// Stops ffmpeg playback: pauses on the last frame shown, which becomes
    /// the still; ffmpeg is stopped and awaited (`RawVideoPipe.finish`), then
    /// the gate goes back. The next decode or start waits for that.
    private func stopFFmpeg() {
        playToken += 1
        playback = .paused
        let task = ffmpegTask
        let source = ffmpegSource
        ffmpegTask = nil
        ffmpegSource = nil
        task?.cancel()
        if let last = ffmpegLastFrame {
            frame = last.frameNumber
            let image = PlayerFrame(image: last.image, requested: last.frameNumber, shown: last.frameNumber)
            still = image
            if let file, let key = stillCacheKey, key.file == file.id, key.width == ffmpegWidth {
                stills.removeAll { $0.frame == last.frameNumber }
                stills.append((last.frameNumber, image))
                if stills.count > Self.stillCacheLimit { stills.removeFirst() }
            }
        }
        ffmpegLastFrame = nil
        showsPlaybackFrame = false
        playbackLayer.contents = nil
        let releases = holdsGate
        holdsGate = false
        let previous = ffmpegStop
        ffmpegStop = Task {
            await previous?.value
            await task?.value
            await source?.close()
            if releases { await DecoderSessionGate.release() }
        }
    }

    // MARK: - Editing at the current frame

    /// Waits until ffmpeg playback has exited and the decode in flight is
    /// done, so a save or check decodes after them, not beside them.
    func waitForDecodes() async {
        await ffmpegStop?.value
        await decodeTask?.value
    }

    /// The current frame for an edit there, after pausing, and whether it
    /// decodes exactly (decision 25: an inexact frame is not stored). Uses
    /// the still when it is the frame's, else decodes the frame. A frame
    /// that does not decode at all counts as exact, as the scrub stores it.
    func exactCurrentFrame() async -> (frame: Int, exact: Bool)? {
        guard isShown, let model, let file else { return nil }
        if playback != .paused { pause() }
        let target = frame
        await waitForDecodes()
        if let still, still.requested == target { return (target, still.isExact) }
        if let cached = stills.first(where: { $0.frame == target }) { return (target, cached.image.isExact) }
        guard let backend = try? await model.backend(for: file),
              let decoded = try? await backend.frame(target, maxWidth: stillWidth(file))
        else { return (target, true) }
        return (target, decoded.isExact)
    }

    // MARK: - Still and frame strip

    /// Decode width of the still: the video area's pixels in steps of 128,
    /// at most the movie's width.
    private func stillWidth(_ file: MovieFile) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Double(videoSize.width) * scale
        let stepped = Int((pixels / 128).rounded(.up)) * 128
        return max(256, min(stepped, max(256, file.width)))
    }

    /// The movie's height / width.
    func aspectRatioInv(_ file: MovieFile) -> Double {
        file.transform.aspectRatioInv ?? (file.width > 0 ? Double(file.height) / Double(file.width) : 9.0 / 16.0)
    }

    /// Width of a whole frame at the strip's height, in points.
    func stripFrameWidth(_ file: MovieFile, height: Double) -> Double {
        height / aspectRatioInv(file)
    }

    /// Decode width of the strip's frames: a whole frame at the strip's
    /// height in pixels, in steps of 32.
    private func stripWidth(_ file: MovieFile) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let stepped = Int((stripFrameWidth(file, height: stripSize.height) * scale / 32).rounded(.up)) * 32
        return max(32, min(stepped, max(32, file.width)))
    }

    /// The strip's layout at the current frame for a strip of `size`.
    func stripGeometry(_ file: MovieFile, size: CGSize) -> FrameStripGeometry {
        FrameStripGeometry(
            stripWidth: size.width, frameWidth: stripFrameWidth(file, height: size.height),
            count: FrameStripGeometry.sliceCount(for: mode), currentFrame: frame, frameCount: file.frameCount,
            cuts: cuts())
    }

    /// A decoded strip slice, if there is one.
    func stripFrame(_ frame: Int) -> PlayerFrame? {
        _ = stripGeneration
        return stripFrames[frame]
    }

    /// The sizes changed: decode again at the new sizes.
    func sizesChanged() {
        if playback == .paused { scheduleDecodes() }
    }

    /// Decodes the still of the current frame, then the strip's missing
    /// frames as runs of consecutive frames (one sequential read each). A
    /// newer frame cancels what is in flight; slices already decoded stay
    /// cached, so stepping by one decodes one frame.
    func scheduleDecodes() {
        decodeTask?.cancel()
        decodeTask = nil
        guard isShown, playback == .paused, let model, let file,
              videoSize.width > 0, stripSize.width > 0, stripSize.height > 0
        else { return }
        let target = frame
        let stillWidth = stillWidth(file)
        let stripWidth = stripWidth(file)
        if stillCacheKey.map({ $0.file != file.id || $0.width != stillWidth }) ?? true {
            stills.removeAll()
            stillCacheKey = (file.id, stillWidth)
        }
        if stripCacheKey.map({ $0.file != file.id || $0.width != stripWidth }) ?? true {
            stripFrames.removeAll()
            stripCacheKey = (file.id, stripWidth)
            stripGeneration += 1
        }
        if let cached = stills.first(where: { $0.frame == target }) { still = cached.image }
        let wanted = stripGeometry(file, size: stripSize).frames
        let missing = wanted.filter { stripFrames[$0] == nil }
        let needsStill = still?.requested != target
        guard needsStill || !missing.isEmpty else { return }
        let stopping = ffmpegStop
        decodeTask = Task {
            try? await Task.sleep(for: Self.decodeDelay)
            // ffmpeg playback has exited before anything decodes.
            await stopping?.value
            guard !Task.isCancelled, let backend = try? await model.backend(for: file) else { return }
            if needsStill, let decoded = try? await backend.frame(target, maxWidth: stillWidth) {
                guard !Task.isCancelled else { return }
                let image = PlayerFrame(image: decoded.image, requested: target, shown: decoded.actualFrame)
                still = image
                stills.removeAll { $0.frame == target }
                stills.append((target, image))
                if stills.count > Self.stillCacheLimit { stills.removeFirst() }
            }
            for run in Self.runs(of: missing) {
                for await result in backend.frameRun(run, maxWidth: stripWidth) {
                    if Task.isCancelled { return }
                    guard case .success(let decoded) = result.result else { continue }
                    stripFrames[result.frameNumber] = PlayerFrame(
                        image: decoded.image, requested: result.frameNumber, shown: decoded.actualFrame)
                    stripGeneration += 1
                }
                if Task.isCancelled { return }
            }
            trimStrip(around: target)
        }
    }

    /// Consecutive stretches of sorted frame numbers.
    static func runs(of frames: [Int]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for frame in frames.sorted() {
            if let last = runs.last, frame == last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...frame
            } else if runs.last?.contains(frame) != true {
                runs.append(frame...frame)
            }
        }
        return runs
    }

    /// Keeps the cache to the frames nearest the current one.
    private func trimStrip(around frame: Int) {
        guard stripFrames.count > Self.stripCacheLimit else { return }
        let keep = stripFrames.keys.sorted { abs($0 - frame) < abs($1 - frame) }.prefix(Self.stripCacheLimit)
        let kept = Set(keep)
        stripFrames = stripFrames.filter { kept.contains($0.key) }
    }
}
