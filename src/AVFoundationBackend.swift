import Foundation
import AVFoundation
import AppKit

// Primary decode backend: in-process AVFoundation with VideoToolbox
// hardware decode. The AVAsset stays resident for the loaded video
// (released on close/replace), so batch extraction and per-cell nudges
// hit a warm decoder with no process spawn. Formats AVFoundation cannot
// open (WebM/MKV, …) fall back to FFmpegBackend via routing in
// AppState+Loading.
final class AVFoundationBackend: DecodeBackend {
    let name = "AVFoundation (VideoToolbox)"
    var logSink: ((String) -> Void)? = nil

    private var asset: AVURLAsset? = nil
    private let stateLock = NSLock()
    private var batchGenerator: AVAssetImageGenerator? = nil
    private var batchCancelled = false

    private func log(_ message: String) {
        DispatchQueue.main.async { self.logSink?(message) }
    }

    // MARK: - Probe / open

    func open(url: URL) -> Result<VideoFileInfo, DecodeBackendError> {
        let candidate = AVURLAsset(url: url)

        // Deployment target is macOS 11: the async load(.duration) API is
        // macOS 12+, so use the completion-handler loading API and wait.
        // Callbacks arrive on a background queue, so blocking here (called
        // on main during load) cannot deadlock.
        let sem = DispatchSemaphore(value: 0)
        candidate.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { sem.signal() }
        guard sem.wait(timeout: .now() + 30) == .success else {
            return .failure(DecodeBackendError(message: "Timed out reading media metadata."))
        }

        var loadError: NSError?
        guard candidate.statusOfValue(forKey: "tracks", error: &loadError) == .loaded else {
            return .failure(DecodeBackendError(
                message: loadError?.localizedDescription ?? "Could not read media tracks."))
        }
        guard let track = candidate.tracks(withMediaType: .video).first, track.isDecodable else {
            return .failure(DecodeBackendError(message: "No decodable video track."))
        }

        var info = VideoFileInfo(url: url)
        let dur = CMTimeGetSeconds(candidate.duration)
        info.duration = (dur.isFinite && dur > 0) ? dur : 0

        let natural = track.naturalSize.applying(track.preferredTransform)
        info.width = Int(abs(natural.width).rounded())
        info.height = Int(abs(natural.height).rounded())
        info.codec = Self.codecName(of: track)
        let fps = track.nominalFrameRate
        info.frameRate = fps > 0 ? String(format: "%g", fps) : ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            info.size = bytes
        }
        info.isLoaded = true

        self.asset = candidate
        return .success(info)
    }

    private static func codecName(of track: AVAssetTrack) -> String {
        guard let first = track.formatDescriptions.first else { return "Unknown" }
        let desc = first as! CMFormatDescription
        let sub = CMFormatDescriptionGetMediaSubType(desc)
        switch sub {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        case kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes4444: return "prores"
        default:
            // Render the fourCC (e.g. 'ap4h') as text
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((sub >> $0) & 0xFF))) }
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Duration estimation

    // AVFoundation-supported containers carry duration metadata; there is
    // no packet-scan equivalent here. Report failure so the caller can
    // surface a clear error (in practice this path is unreachable for
    // AVF-routed files).
    func estimateDuration(url: URL, completion: @escaping (Double?, Bool) -> Void) {
        log(">>> AVFoundation reported no duration; no estimation available on this backend.\n")
        DispatchQueue.main.async { completion(nil, false) }
    }

    // MARK: - Extraction

    // Bounded tolerance for the per-frame retry when an exact-time decode
    // fails (see Decisions: some real-world H.264 streams hard-fail
    // zero-tolerance generation on scattered frames).
    private static let retryTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    private func makeGenerator(scaleWidth: Int, asset: AVAsset, exact: Bool) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: asset)
        // Rotated-metadata videos must come out upright
        gen.appliesPreferredTrackTransform = true
        // Exact frames first: the export is timestamp-accurate. Coarse
        // tolerance is a scrub-UI concern (Phase 3b, not built). The
        // non-exact variant is only used for the bounded failure retry.
        gen.requestedTimeToleranceBefore = exact ? .zero : Self.retryTolerance
        gen.requestedTimeToleranceAfter = exact ? .zero : Self.retryTolerance
        // Width-constrained, aspect-preserving (0 = unconstrained axis)
        gen.maximumSize = CGSize(width: scaleWidth, height: 0)
        return gen
    }

    private static func writeJPEG(_ cgImage: CGImage, to path: String) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    func extractFrames(url: URL, timestamps: [Double], scaleWidth: Int, tempDir: String,
                       completion: @escaping (Int, Bool, [Int: Double]) -> Void) {
        guard let asset = asset, !timestamps.isEmpty else {
            DispatchQueue.main.async { completion(0, false, [:]) }
            return
        }
        let gen = makeGenerator(scaleWidth: scaleWidth, asset: asset, exact: true)
        stateLock.lock()
        batchCancelled = false
        batchGenerator = gen
        stateLock.unlock()

        let times = timestamps.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        // requestedTime -> pending indices (robust to duplicate timestamps
        // and to callbacks arriving in any order)
        var indexQueues: [NSValue: [Int]] = [:]
        for (i, v) in times.enumerated() { indexQueues[v, default: []].append(i) }

        let lock = NSLock()
        var extracted = 0
        var remaining = times.count
        var sawCancel = false
        // Exact-time decode failures collected for the bounded-tolerance
        // retry pass (index -> requested seconds)
        var retryQueue: [(index: Int, seconds: Double)] = []

        gen.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cgImage, _, result, error in
            let key = NSValue(time: requestedTime)
            lock.lock()
            let index = indexQueues[key]?.first
            if index != nil { indexQueues[key]?.removeFirst() }
            lock.unlock()

            switch result {
            case .succeeded:
                if let cg = cgImage, let i = index {
                    let outPath = String(format: "%@/thumb_%04d.jpg", tempDir, i + 1)
                    if Self.writeJPEG(cg, to: outPath) {
                        lock.lock(); extracted += 1; lock.unlock()
                    } else {
                        self.log("Frame \(i + 1): failed to write JPEG.\n")
                    }
                }
            case .cancelled:
                lock.lock(); sawCancel = true; lock.unlock()
            case .failed:
                if let i = index {
                    lock.lock(); retryQueue.append((i, CMTimeGetSeconds(requestedTime))); lock.unlock()
                } else {
                    self.log("Frame ?: \(error?.localizedDescription ?? "decode failed")\n")
                }
            @unknown default:
                break
            }

            lock.lock()
            remaining -= 1
            let done = remaining == 0
            lock.unlock()
            guard done else { return }

            self.stateLock.lock()
            if self.batchGenerator === gen { self.batchGenerator = nil }
            let hardCancel = self.batchCancelled
            self.stateLock.unlock()

            lock.lock()
            let retries = retryQueue
            var total = extracted
            let cancelled = sawCancel || hardCancel
            lock.unlock()

            // Bounded-tolerance retry for exact-time failures (skipped when
            // the batch was cancelled).
            var timeOverrides: [Int: Double] = [:]
            if !cancelled && !retries.isEmpty {
                let retryGen = self.makeGenerator(scaleWidth: scaleWidth, asset: asset, exact: false)
                for (i, seconds) in retries {
                    do {
                        var actual = CMTime.zero
                        let cg = try retryGen.copyCGImage(
                            at: CMTime(seconds: seconds, preferredTimescale: 600),
                            actualTime: &actual)
                        let outPath = String(format: "%@/thumb_%04d.jpg", tempDir, i + 1)
                        if Self.writeJPEG(cg, to: outPath) {
                            total += 1
                            let actualSec = CMTimeGetSeconds(actual)
                            if abs(actualSec - seconds) > 0.0005 { timeOverrides[i] = actualSec }
                            self.log(">>> Frame \(i + 1): exact-time decode failed; retried with ±0.5s tolerance (got t=\(String(format: "%.3f", actualSec))s).\n")
                        } else {
                            self.log("Frame \(i + 1): failed to write JPEG after retry.\n")
                        }
                    } catch {
                        self.log("Frame \(i + 1) (t=\(String(format: "%.1f", seconds))s): \(error.localizedDescription)\n")
                    }
                }
            }

            let finalTotal = total
            DispatchQueue.main.async {
                completion(finalTotal, cancelled, timeOverrides)
            }
        }
    }

    func extractSingleFrame(url: URL, timestamp: Double, scaleWidth: Int, outPath: String,
                            completion: @escaping (Bool, String?, Double?) -> Void) {
        guard let asset = asset else {
            DispatchQueue.main.async { completion(false, "No open asset.", nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let requested = CMTime(seconds: timestamp, preferredTimescale: 600)
            do {
                let gen = self.makeGenerator(scaleWidth: scaleWidth, asset: asset, exact: true)
                let cg = try gen.copyCGImage(at: requested, actualTime: nil)
                let ok = Self.writeJPEG(cg, to: outPath)
                DispatchQueue.main.async {
                    completion(ok, ok ? nil : "Failed to encode frame.\n", nil)
                }
            } catch {
                // Exact-time decode failed; bounded-tolerance retry
                do {
                    let retryGen = self.makeGenerator(scaleWidth: scaleWidth, asset: asset, exact: false)
                    var actual = CMTime.zero
                    let cg = try retryGen.copyCGImage(at: requested, actualTime: &actual)
                    let ok = Self.writeJPEG(cg, to: outPath)
                    let actualSec = CMTimeGetSeconds(actual)
                    self.log(">>> Nudge: exact-time decode failed; retried with ±0.5s tolerance (got t=\(String(format: "%.3f", actualSec))s).\n")
                    let override = abs(actualSec - timestamp) > 0.0005 ? actualSec : nil
                    DispatchQueue.main.async {
                        completion(ok, ok ? nil : "Failed to encode frame.\n", override)
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(false, error.localizedDescription + "\n", nil)
                    }
                }
            }
        }
    }

    // MARK: - Cancellation / teardown

    @discardableResult
    func cancelAll() -> Bool {
        stateLock.lock()
        let gen = batchGenerator
        if gen != nil { batchCancelled = true }
        stateLock.unlock()
        gen?.cancelAllCGImageGeneration()
        return gen != nil
    }

    func close() {
        cancelAll()
        stateLock.lock()
        batchGenerator = nil
        stateLock.unlock()
        asset = nil
    }
}
