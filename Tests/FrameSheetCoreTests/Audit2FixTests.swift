import CoreGraphics
import Foundation
import Testing
@testable import FrameSheetCore

// The second pre-release audit (2026-11-06): tests of the fixes that added
// new code (the reproductions on the audited code are in
// Audit2ReproTests.swift).

// MARK: - B6. A saved print's pixels match its labels

@Suite struct PrintFramesTests {
    private static func solid(red: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    private static func red(_ image: CGImage?) -> Int? {
        guard let image else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0])
    }

    /// Thumbs 10 and 11 decoded as 11 and 12 (the audit's case): each keeps
    /// its own pixels (in the audited loop frame 11's image overwrote the
    /// one thumb 11 needed, so slot 12 printed frame 11's pixels).
    @Test func retargetedThumbsKeepTheirOwnPixels() {
        let thumbs = [Thumb(frameNumber: 10, index: 0), Thumb(frameNumber: 11, index: 1)]
        let decoded: [Int: PrintFrames.Decoded<CGImage>] = [
            10: .init(image: Self.solid(red: 1, blue: 0), shown: 11),
            11: .init(image: Self.solid(red: 0, blue: 1), shown: 12),
        ]
        let resolved = PrintFrames.resolve(thumbs, decoded: decoded)
        #expect(resolved.thumbs.map(\.frameNumber) == [11, 12])
        #expect(Self.red(resolved.images[thumbs[0].id]) == 255)
        #expect(Self.red(resolved.images[thumbs[1].id]) == 0)
        #expect(resolved.shown == [10: 11, 11: 12])
        // The embedded data names the same frames.
        let sheet = Sheet(name: "Sheet-1", type: .interval, thumbs: thumbs).retargeted(resolved.shown)
        #expect(sheet.thumbs.map(\.frameNumber) == [11, 12])
    }

    @Test func missingFramesHaveNoImage() {
        let thumbs = [Thumb(frameNumber: 3, index: 0)]
        let resolved = PrintFrames.resolve(thumbs, decoded: [Int: PrintFrames.Decoded<CGImage>]())
        #expect(resolved.images.isEmpty && resolved.thumbs.map(\.frameNumber) == [3] && resolved.shown.isEmpty)
    }
}

// MARK: - B11. A face scan that analyzed nothing says so

@Suite struct FaceScanNoticeTests {
    @Test func noFrameAnalyzed() {
        let message = FaceScanNotice.noFaces(
            fileName: "a.mov", requested: [10, 20], data: FaceData(thresholds: FaceThresholds()), detail: ".")
        #expect(message == "No frame of a.mov could be analyzed for faces (2 requested).")
    }

    @Test func someFramesAnalyzed() {
        var data = FaceData(thresholds: FaceThresholds())
        data.record(FaceFrame(frameNumber: 10, faces: []))
        let message = FaceScanNotice.noFaces(fileName: "a.mov", requested: [10, 20], data: data, detail: ".")
        #expect(message == "No faces found in a.mov (1 of 2 frames analyzed).")
    }
}

// MARK: - C. Waits a cancelled caller does not stay in

@Suite struct CancellableWaitTests {
    /// A shared open that never ends: a cancelled waiter returns at once.
    @Test func cancelledWaiterStopsWaiting() async {
        let shared = Task<Int, any Error> {
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        defer { shared.cancel() }
        let started = ContinuousClock.now
        let waiter = Task { try await cancellableValue(of: shared) }
        try? await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func valueArrives() async throws {
        let shared = Task<Int, any Error> { 7 }
        #expect(try await cancellableValue(of: shared) == 7)
    }

    /// `ScanProducers.stop` returns only after the producer's last write.
    @Test func producersAreAwaited() async {
        let id = UUID()
        let wrote = Flag()
        let task = Task {
            // Ignores cancellation for a while, then "stores".
            let until = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < until { await Task.yield() }
            wrote.set()
        }
        ScanProducers.track(id, task)
        await ScanProducers.stop(id)
        #expect(wrote.value)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}
