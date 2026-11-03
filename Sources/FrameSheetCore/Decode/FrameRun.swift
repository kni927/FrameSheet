import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

// The player's frame strip (§9) needs runs of consecutive frames around the
// current one. One request per slice would open a generator session per
// frame; instead the run is read with one `AVAssetReader` pass over the
// frames, from a keyframe without leading frames before them
// (`ClosedGOPStart`, as the shot scan resumes), at the strip's size. The run
// holds the DecodeGate for its whole pass (KNOWN_ISSUES 4). Frames the pass
// does not deliver (open-GOP files with no closed GOP close enough, rotated
// tracks, a reader that stops) go through ffmpeg in one run when the exact
// fallback is on, then through the single-frame steps of decision 25.

extension AVFoundationBackend {
    public func frameRun(_ range: ClosedRange<Int>, maxWidth: Int) -> AsyncStream<FrameResult> {
        frameRun(range, maxWidth: maxWidth, preRoll: EarlierGOPReader.runPreRoll)
    }

    /// `preRoll`: how far before the run a closed-GOP start may lie (tests
    /// shorten it to reach the later steps).
    func frameRun(_ range: ClosedRange<Int>, maxWidth: Int, preRoll: CMTime) -> AsyncStream<FrameResult> {
        let last = max(0, info.frameCount - 1)
        let low = min(max(0, range.lowerBound), last)
        let run = low...min(max(low, range.upperBound), last)
        return AsyncStream { continuation in
            let task = Task {
                await DecodeGate.shared.acquire()
                await self.readRun(run, maxWidth: maxWidth, preRoll: preRoll) { continuation.yield($0) }
                await DecodeGate.shared.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The run's steps; callers hold the gate.
    private func readRun(
        _ range: ClosedRange<Int>, maxWidth: Int, preRoll: CMTime, yield: (FrameResult) -> Void
    ) async {
        var done = Set<Int>()
        func send(_ frame: DecodedFrame) {
            done.insert(frame.requestedFrame)
            yield(FrameResult(
                index: frame.requestedFrame - range.lowerBound, frameNumber: frame.requestedFrame,
                result: .success(frame)))
        }
        // 1. One sequential read.
        do {
            try await reader.readRun(range, maxWidth: maxWidth, preRoll: preRoll) { number, image in
                guard !done.contains(number) else { return }
                send(DecodedFrame(
                    image: image, requestedFrame: number, actualFrame: number, retried: false,
                    decoder: .avFoundationReader))
            }
        } catch {
            if Task.isCancelled { return }
        }
        // 2. ffmpeg, one run over the frames still missing (fallback on).
        var missing = range.filter { !done.contains($0) }
        if let low = missing.first, let high = missing.last, let fallback {
            let wanted = Set(missing)
            let frames = (try? await fallback.frameRun(low...high, maxWidth: maxWidth)) ?? []
            for frame in frames where wanted.contains(frame.actualFrame) && !done.contains(frame.actualFrame) {
                var exact = frame
                exact.requestedFrame = frame.actualFrame
                exact.retried = false
                send(exact)
            }
            missing = range.filter { !done.contains($0) }
        }
        // 3. The rest one by one: the exact request, the earlier-GOP read,
        // then the retry (ffmpeg was tried above).
        for number in missing {
            if Task.isCancelled { return }
            do {
                send(try await decodeFrame(number, maxWidth: maxWidth, useFallback: false))
            } catch {
                if Task.isCancelled { return }
                let message = (error as? DecodeError) ?? DecodeError(error.localizedDescription)
                yield(FrameResult(index: number - range.lowerBound, frameNumber: number, result: .failure(message)))
            }
        }
    }

    /// The first frame from which AVPlayer, starting playback at `frame`,
    /// shows the frames it plays: `frame` itself, or, when `frame` is a
    /// leading frame of an open GOP (decoded after its keyframe but shown
    /// before it, with references into the GOP before), that keyframe's
    /// frame. A playback that starts there decodes from that keyframe, as
    /// the exact image request does, and cannot show the leading frames
    /// (KNOWN_ISSUES 5); from the keyframe on it decodes in order. Reads the
    /// sample table only; `frame` itself without sample cursors.
    public func firstPlayableFrame(from frame: Int) async -> Int {
        let fps = info.fps > 0 ? info.fps : 25
        let time = CMTime(seconds: startTime + (Double(frame) + 0.25) / fps, preferredTimescale: 600_000)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let offset = try? await reader.mediaOffset(track),
              let cursor = track.makeSampleCursor(presentationTimeStamp: time - offset)
        else { return frame }
        let shown = cursor.presentationTimeStamp
        // Back in decode order to the keyframe the decode starts from.
        for _ in 0..<ClosedGOPStart.maximumSteps {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                guard cursor.presentationTimeStamp > shown else { return frame }
                let keyframe = (cursor.presentationTimeStamp + offset).seconds
                return max(frame, Int(((keyframe - startTime) * fps).rounded()))
            }
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { return frame }
        }
        return frame
    }
}

extension EarlierGOPReader {
    /// How far before the run a closed-GOP start may lie; past that the run
    /// starts one GOP before its first frame and may stop on open-GOP files.
    static let runPreRoll = CMTime(seconds: 10, preferredTimescale: 600)

    /// Reads the frames of `range` in one pass, scaled to at most `maxWidth`
    /// pixels wide, handing each frame whose time maps to a frame of the
    /// range to `deliver` in order. Returns without reading for a rotated
    /// track or without sample cursors; a reader that stops part way
    /// (AVErrorDecodeFailed on an open GOP) ends the pass early. Throws only
    /// when cancelled.
    func readRun(
        _ range: ClosedRange<Int>, maxWidth: Int, preRoll: CMTime = runPreRoll, deliver: (Int, CGImage) -> Void
    ) async throws {
        guard usable else { return }
        let fps = info.fps
        let frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
        let first = CMTime(seconds: startTime + Double(range.lowerBound) / fps, preferredTimescale: 600_000)
        let last = CMTime(seconds: startTime + Double(range.upperBound) / fps, preferredTimescale: 600_000)
        let width = min(max(1, maxWidth), info.width)
        let height = max(1, Int((Double(width) * Double(info.height) / Double(info.width)).rounded()))
        // A quarter frame of slack, as for the generator's actual time.
        let slack = 0.25 / fps
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let offset = try await mediaOffset(track)
            let resume = first - CMTime(seconds: slack, preferredTimescale: 600_000)
            var start = await ClosedGOPStart.time(track, atOrBefore: resume, notBefore: resume - preRoll)
            if start == nil { start = Self.previousSyncTime(track, before: first, offset: offset) }
            guard let start else { return }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: min(start, first), end: last + frameDuration)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            let provider = reader.outputProvider(for: output)
            try reader.start()
            defer { reader.cancelReading() }
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                let pts = sample.presentationTimeStamp.seconds
                guard pts.isFinite else { continue }
                if pts > last.seconds + slack { break }
                let number = Int(((pts - startTime) * fps).rounded())
                guard range.contains(number),
                      abs(pts - (startTime + Double(number) / fps)) <= slack
                else { continue }
                let image: CGImage? = sample.withUnsafeSampleBuffer { buffer in
                    guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
                    var image: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
                    return image
                }
                if let image { deliver(number, image) }
                if number >= range.upperBound { break }
            }
        } catch {
            try Task.checkCancellation()
        }
    }
}
