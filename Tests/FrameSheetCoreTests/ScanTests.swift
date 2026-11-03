import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import FrameSheetCore

// MARK: - Synthetic frames

/// A BGRA image filled per pixel by `color(x, y)` as (r, g, b).
private final class TestImage {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int = 48, height: Int = 27, color: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = b
                bytes[i + 1] = g
                bytes[i + 2] = r
            }
        }
    }

    convenience init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.init { _, _ in (r, g, b) }
    }

    func with<T>(_ body: (BGRAFrame) -> T) -> T {
        bytes.withUnsafeBytes { body(BGRAFrame(base: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4)) }
    }
}

@Suite struct ShotMetricTests {
    @Test func hsvMatchesOpenCV() {
        func hsv(_ r: Int32, _ g: Int32, _ b: Int32) -> [Int32] {
            let c = HSV8.convert(red: r, green: g, blue: b)
            return [c.h, c.s, c.v]
        }
        #expect(hsv(255, 0, 0) == [0, 255, 255])
        #expect(hsv(0, 255, 0) == [60, 255, 255])
        #expect(hsv(0, 0, 255) == [120, 255, 255])
        #expect(hsv(90, 90, 90) == [0, 0, 90])
        // Magenta-ish red: hue below 0 wraps to 150–179.
        let pink = HSV8.convert(red: 255, green: 0, blue: 128)
        #expect(pink.h > 150 && pink.h < 180)
    }

    @Test func hsvToRGB() {
        #expect(ShotMetrics.hsvToRGB(h: 0, s: 0, v: 128) == RGB8(red: 128, green: 128, blue: 128))
        #expect(ShotMetrics.hsvToRGB(h: 60, s: 255, v: 255) == RGB8(red: 0, green: 255, blue: 0))
        #expect(ShotMetrics.hsvToRGB(h: 120, s: 255, v: 200) == RGB8(red: 0, green: 0, blue: 200))
    }

    @Test func meanDifferenceAndColor() {
        let metric = ShotMetricCalculator(method: .mean)
        let first = TestImage(100, 100, 100).with { metric.measure($0) }
        #expect(first.difference == 0)
        #expect(first.color == RGB8(red: 100, green: 100, blue: 100))
        let second = TestImage(200, 50, 50).with { metric.measure($0) }
        #expect(second.difference == 100)
        // HSV mean back to RGB: close to the frame's color.
        #expect(abs(Int(second.color.red) - 200) <= 1 && abs(Int(second.color.green) - 50) <= 1)
        // Half black, half white: mean V 127.5.
        let half = TestImage { x, _ in x < 24 ? (0, 0, 0) : (255, 255, 255) }.with { metric.measure($0) }
        #expect(abs(half.difference - 72.5) < 0.001)
        let same = TestImage { x, _ in x < 24 ? (0, 0, 0) : (255, 255, 255) }.with { metric.measure($0) }
        #expect(same.difference == 0)
    }

    @Test func histogramChiSquare() {
        let metric = ShotMetricCalculator(method: .histogram)
        let first = TestImage(100, 100, 100).with { metric.measure($0) }
        #expect(first.difference == 0)
        #expect(first.color == RGB8(red: 100, green: 100, blue: 100))
        #expect(TestImage(100, 100, 100).with { metric.measure($0) }.difference == 0)
        // Two one-bin histograms, each normalized to 1: 2 · (1 + 1) = 4.
        let other = TestImage(200, 200, 200).with { metric.measure($0) }
        #expect(abs(other.difference - 4) < 1e-5)
        // Half the pixels in each bin (1/√2 each) against one bin.
        let half = TestImage { x, _ in x < 24 ? (100, 100, 100) : (200, 200, 200) }.with { metric.measure($0) }
        let a = 1 / 2.0.squareRoot()
        let expected = 2 * ((1 - a) * (1 - a) / (1 + a) + a * a / a)
        #expect(abs(Double(half.difference) - expected) < 1e-5)
        // The color is the RGB mean.
        #expect(half.color == RGB8(red: 150, green: 150, blue: 150))
    }

    @Test func chiSquareSkipsEmptyBins() {
        #expect(ShotMetrics.chiSquareAlternative([0, 1, 0], [0, 0, 1]) == 4)
        #expect(ShotMetrics.chiSquareAlternative([0, 0], [0, 0]) == 0)
    }

    @Test func meanVForInOut() {
        #expect(TestImage(10, 40, 20).with { ShotMetrics.meanV($0) } == 40)
    }

    @Test func orientationFromTransform() {
        #expect(FrameOrientation(.identity).isIdentity)
        let quarter = FrameOrientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0))
        #expect(quarter.swapsAxes && !quarter.mirrored)
        #expect(!FrameOrientation(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)).swapsAxes)
    }

    @Test func geometryFits() {
        func fit(_ w: Int, _ h: Int, _ side: Int) -> [Int] {
            let size = ScanGeometry.fit(width: w, height: h, maxSide: side)
            return [size.width, size.height]
        }
        #expect(fit(1920, 1080, 720) == [720, 406])
        #expect(fit(1080, 1920, 240) == [136, 240])
        #expect(fit(320, 180, 720) == [320, 180])
    }
}

// MARK: - Scene list

private func differences(_ count: Int, _ cuts: [Int: Float]) -> [Float] {
    var array = [Float](repeating: 0, count: count)
    for (i, v) in cuts { array[i] = v }
    return array
}

private func starts(_ spans: [SceneSpan]) -> [Int] { spans.map(\.start) }

@Suite struct SceneListTests {
    private func scenes(_ d: [Float], _ threshold: Double = 6) -> [SceneSpan] {
        SceneList.scenes(differences: d, threshold: threshold) { [$0, $0, $0] }
    }

    @Test func cutsAtThreshold() {
        let list = scenes(differences(100, [30: 50, 60: 6, 80: 5.9]))
        #expect(starts(list) == [0, 30, 60])
        #expect(list.map(\.length) == [30, 30, 40])
        // Middle-frame colors; the last scene is gray.
        #expect(list[0].colorRGB == [15, 15, 15])
        #expect(list[1].colorRGB == [45, 45, 45])
        #expect(list[2].colorRGB == SceneList.lastSceneColor)
        #expect(list.map(\.length).reduce(0, +) == 100)
    }

    @Test func tenFrameWindow() {
        // Ten frames after a cut is enough; nine is not.
        #expect(starts(scenes(differences(100, [30: 50, 40: 50]))) == [0, 30, 40])
        // At 39 (previous frame 0) the larger value moves the cut from 30.
        #expect(starts(scenes(differences(100, [30: 50, 39: 50]))) == [0, 39])
    }

    @Test func largerDifferenceMovesTheCut() {
        // Right after a stronger cut, a weaker one does not move it…
        #expect(starts(scenes(differences(100, [30: 50, 31: 20]))) == [0, 30])
        // …a stronger one does.
        #expect(starts(scenes(differences(100, [30: 8, 31: 40]))) == [0, 31])
        // MoviePrint compares with the previous frame, so a later weaker
        // value after a quiet frame moves it as well.
        #expect(starts(scenes(differences(100, [30: 50, 35: 7]))) == [0, 35])
        // Below the threshold nothing moves.
        #expect(starts(scenes(differences(100, [30: 50, 35: 5]))) == [0, 30])
    }

    @Test func cutInsideTheFirstWindow() {
        // A cut 5 frames in: the first scene is 0–4 (MoviePrint's
        // "first scene within SCENE_DETECTION_MIN_SCENE_LENGTH").
        let list = scenes(differences(100, [5: 50]))
        #expect(starts(list) == [0, 5])
        #expect(list[0].length == 5)
        #expect(scenes([]).isEmpty)
        #expect(scenes([0]).map(\.length) == [1])
    }

    @Test func thresholdChangeRebuildsFromTheCache() throws {
        var scan = ScanData(method: .mean, expectedFrameCount: 200)
        for i in 0..<200 {
            let d: Float = [50: 40, 100: 10, 150: 25][i] ?? 0
            scan.append(difference: d, color: RGB8(red: UInt8(i), green: 0, blue: 0))
        }
        #expect(starts(SceneList.scenes(from: scan, threshold: 6)) == [0, 50, 100, 150])
        #expect(starts(SceneList.scenes(from: scan, threshold: 20)) == [0, 50, 150])
        #expect(starts(SceneList.scenes(from: scan, threshold: 30)) == [0, 50])

        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 8, frameCount: 200, fps: 25,
            width: 640, height: 360, size: 1, fourCC: "avc1")
        library.files.append(file)
        let added = library.addShotSheet(to: file.id, scenes: SceneList.scenes(from: scan, threshold: 6))
        let sheet = try #require(added)
        #expect(sheet.type == .shot && sheet.view == .timeline)
        #expect(sheet.thumbs.map(\.frameNumber) == [25, 75, 125, 175])
        #expect(sheet.thumbs.map(\.id) == sheet.scenes.map(\.id))
        #expect(sheet.scenes[0].colorRGB == [25, 0, 0])
        let ref = SheetRef(fileId: file.id, sheetId: sheet.id)
        library.replaceScenes(ref, with: SceneList.scenes(from: scan, threshold: 30))
        let rebuilt = library.sheet(sheet.id, of: file.id)!
        #expect(rebuilt.scenes.map(\.start) == [0, 50])
        #expect(rebuilt.thumbs.map(\.frameNumber) == [25, 125])
        #expect(rebuilt.thumbs.map(\.index) == [0, 1])
    }
}

@Suite struct SceneEditingTests {
    private func fixture() -> (Library, SheetRef) {
        var library = Library()
        let file = MovieFile(
            url: URL(fileURLWithPath: "/movies/a.mp4"), duration: 12, frameCount: 300, fps: 25,
            width: 640, height: 360, size: 1, fourCC: "avc1")
        library.files.append(file)
        let spans = [
            SceneSpan(start: 0, length: 100, colorRGB: [10, 20, 30]),
            SceneSpan(start: 100, length: 200, colorRGB: [128, 128, 128]),
        ]
        let sheet = library.addShotSheet(to: file.id, scenes: spans)!
        return (library, SheetRef(fileId: file.id, sheetId: sheet.id))
    }

    @Test func cutSplitsAndMovesThumbs() throws {
        var (library, ref) = fixture()
        let second = library.sheet(ref.sheetId, of: ref.fileId)!.scenes[1]
        let cut = library.cutScene(ref, scene: second.id, at: 150)
        let newId = try #require(cut)
        let sheet = library.sheet(ref.sheetId, of: ref.fileId)!
        #expect(sheet.scenes.map(\.start) == [0, 100, 150])
        #expect(sheet.scenes.map(\.length) == [100, 50, 150])
        #expect(sheet.scenes[2].id == newId && sheet.scenes[2].colorRGB == second.colorRGB)
        #expect(sheet.thumbs.map(\.frameNumber) == [50, 125, 225])
        #expect(sheet.thumbs.map(\.id) == sheet.scenes.map(\.id))
        #expect(sheet.thumbs.map(\.index) == [0, 1, 2])
        // A frame outside the scene, or its first frame, does not cut.
        let atStart = library.cutScene(ref, scene: second.id, at: 100)
        let outside = library.cutScene(ref, scene: second.id, at: 150)
        #expect(atStart == nil && outside == nil)
    }

    @Test func mergeJoinsAtTheCut() throws {
        var (library, ref) = fixture()
        let second = library.sheet(ref.sheetId, of: ref.fileId)!.scenes[1]
        library.cutScene(ref, scene: second.id, at: 150)
        #expect(library.adjacentSceneIndices(ref, cut: 150).map { [$0.0, $0.1] } == [1, 2])
        let merged = library.mergeScenes(ref, cut: 150)
        #expect(merged)
        var sheet = library.sheet(ref.sheetId, of: ref.fileId)!
        #expect(sheet.scenes.map(\.start) == [0, 100])
        #expect(sheet.scenes[1].id == second.id && sheet.scenes[1].length == 200)
        #expect(sheet.thumbs.map(\.frameNumber) == [50, 200])
        let mergedAll = library.mergeScenes(ref, cut: 100)
        #expect(mergedAll)
        sheet = library.sheet(ref.sheetId, of: ref.fileId)!
        #expect(sheet.scenes.map(\.length) == [300])
        #expect(sheet.scenes[0].colorRGB == [10, 20, 30])
        #expect(sheet.thumbs.map(\.frameNumber) == [150])
        // The first scene has no cut before it; no scene starts at 77.
        let atStart = library.mergeScenes(ref, cut: 0)
        let nowhere = library.mergeScenes(ref, cut: 77)
        #expect(!atStart && !nowhere)
    }
}

@Suite struct AutoInOutTests {
    @Test func ranges() throws {
        let long = try #require(AutoInOut.searchRanges(frameCount: 1001))
        #expect(long.in == 0..<300)
        #expect(long.out == 700...1000)
        let short = try #require(AutoInOut.searchRanges(frameCount: 60))
        // Last frame 59, length 29.5.
        #expect(short.in == 0..<30)
        #expect(short.out == 30...59)
        #expect(AutoInOut.searchRanges(frameCount: 1) == nil)
    }

    @Test func firstFrameAboveThresholdFromEachEnd() {
        let inMeans = [(0, 2.0), (1, 5.0), (2, 25.0)].map { (frame: $0.0, mean: $0.1) }
        let outMeans = [(700, 90.0), (701, 30.0), (702, 1.0), (703, 0.0)].map { (frame: $0.0, mean: $0.1) }
        let points = AutoInOut.points(inMeans: inMeans, outMeans: outMeans, lastFrame: 703)
        #expect(points.inFrame == 2)
        #expect(points.outFrame == 701)
    }

    @Test func brightestFallback() {
        // Nothing above 20: the brightest frame; ties go to the later frame
        // for IN and to the earlier one for OUT.
        let inMeans = [(0, 2.0), (1, 9.0), (2, 9.0), (3, 4.0)].map { (frame: $0.0, mean: $0.1) }
        let outMeans = [(10, 3.0), (11, 12.0), (12, 12.0), (13, 0.0)].map { (frame: $0.0, mean: $0.1) }
        let points = AutoInOut.points(inMeans: inMeans, outMeans: outMeans, lastFrame: 13)
        #expect(points.inFrame == 2)
        #expect(points.outFrame == 11)
        // Exactly 20 is not above the threshold.
        let exact = AutoInOut.points(
            inMeans: [(frame: 0, mean: 20.0)], outMeans: [(frame: 5, mean: 20.0), (frame: 6, mean: 0)], lastFrame: 6)
        #expect(exact.inFrame == 0 && exact.outFrame == 5)
        let empty = AutoInOut.points(inMeans: [], outMeans: [], lastFrame: 9)
        #expect(empty.inFrame == 0 && empty.outFrame == 9)
    }
}

@Suite struct ScanCacheTests {
    private func sample(complete: Bool) -> ScanData {
        var scan = ScanData(method: .histogram, expectedFrameCount: 1234)
        for i in 0..<500 {
            scan.append(difference: Float(i) * 0.37, color: RGB8(red: UInt8(i % 256), green: 7, blue: 200))
        }
        scan.complete = complete
        return scan
    }

    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetScans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScanCacheStore(directory: dir)
        let id = UUID()
        #expect(try store.load(id) == nil)
        for complete in [false, true] {
            let scan = sample(complete: complete)
            try store.save(scan, for: id)
            #expect(try store.load(id) == scan)
        }
        // 32-byte header, 7 bytes per frame.
        let size = try FileManager.default.attributesOfItem(atPath: store.url(for: id).path)[.size] as? Int
        #expect(size == 32 + 500 * 7)
        store.delete(id)
        #expect(try store.load(id) == nil)
    }

    @Test func malformedFileThrows() {
        #expect(throws: (any Error).self) { try ScanCacheStore.decode(Data("nope".utf8)) }
        var data = ScanCacheStore.encode(sample(complete: true))
        data.removeLast()
        #expect(throws: (any Error).self) { try ScanCacheStore.decode(data) }
    }

    @Test func gapsRepeatThePreviousFrame() {
        var scan = ScanData(method: .mean, expectedFrameCount: 3)
        scan.appendRepeatingLast()
        scan.append(difference: 9, color: RGB8(red: 1, green: 2, blue: 3))
        scan.appendRepeatingLast()
        #expect(scan.differences == [0, 9, 0])
        #expect(scan.color(at: 0) == .black)
        #expect(scan.color(at: 2) == RGB8(red: 1, green: 2, blue: 3))
    }
}

@Suite struct ScanSettingsTests {
    @Test func defaultsAndTolerantDecoding() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(settings.shotDetectionMethod == .mean)
        #expect(settings.shotDetectionThreshold == 6)
        #expect(!settings.automaticInOut)
        #expect(!settings.timelineNaturalFlow)
        #expect(settings.timelineSceneWidthRatio == 50)
        #expect(settings.timelineMinSceneLength == 10)
        let odd = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"shotDetectionMethod":"other","shotDetectionThreshold":99}"#.utf8))
        #expect(odd.shotDetectionMethod == .mean)
        #expect(odd.shotDetectionThreshold == 40)
        var changed = Settings()
        changed.shotDetectionMethod = .histogram
        changed.automaticInOut = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(changed))
        #expect(back == changed)
    }
}

// MARK: - Scanning real clips

private final class Locked<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ value: T) { self.value = Mutex(value) }
    func get() -> T { value.withLock { $0 } }
    func set(_ new: T) { value.withLock { $0 = new } }
}

/// Records what a scan's frame hook sees.
private final class RecordingObserver: ScanFrameObserver {
    struct State {
        var frames: [Int] = []
        var size: (Int, Int)?
        var brightQuadrant: Int?
    }

    let state = Mutex(State())
    /// Runs once, when this frame is seen.
    let trigger: Int?
    let action: (@Sendable () async -> Void)?

    init(trigger: Int? = nil, action: (@Sendable () async -> Void)? = nil) {
        self.trigger = trigger
        self.action = action
    }

    func scanned(_ frame: ScanFrame) async {
        let quadrant = frame.frameNumber == 0 ? brightestQuadrant(frame.image) : nil
        state.withLock {
            $0.frames.append(frame.frameNumber)
            if frame.frameNumber == 0 {
                $0.size = (frame.image.width, frame.image.height)
                $0.brightQuadrant = quadrant
            }
        }
        if frame.frameNumber == trigger { await action?() }
    }
}

/// 0 top left, 1 top right, 2 bottom left, 3 bottom right.
private func brightestQuadrant(_ image: BGRAFrame) -> Int {
    var sums = [Int](repeating: 0, count: 4)
    for y in 0..<image.height {
        let row = (image.base + y * image.bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<image.width {
            let q = (y < image.height / 2 ? 0 : 2) + (x < image.width / 2 ? 0 : 1)
            sums[q] += Int(row[x * 4 + 1])
        }
    }
    return sums.indices.max { sums[$0] < sums[$1] }!
}

private func brightestQuadrant(_ image: CGImage) -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels.withUnsafeBytes {
        brightestQuadrant(BGRAFrame(base: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4))
    }
}

/// Scans clips made by the system ffmpeg (skipped without it): 120 frames at
/// 25 fps of flat gray segments with hard cuts at frames 30, 55 and 90.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ShotScanIntegrationTests {
    static var tools: FFmpegTools? { DecodeIntegrationTests.tools }
    static let cuts = [0, 30, 55, 90]
    static let frameCount = 120

    private static func makeClip(_ name: String, filter: String, frames: Int = frameCount) async throws -> URL {
        let tools = try #require(tools)
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetScanClips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        let result = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=320x180:r=25:d=\(frames / 25 + 1),format=yuv420p,\(filter)",
            "-frames:v", "\(frames)", "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", url.path,
        ])
        #expect(result.status == 0, "\(result.stderrText)")
        return url
    }

    /// Gray levels (limited-range Y) 40, 200, 100 and 230.
    static let segments = "geq=lum='if(lt(N,30),40,if(lt(N,55),200,if(lt(N,90),100,230)))':cb=128:cr=128"

    private struct Result {
        var events: [ScanEvent] = []
        var data: ScanData?
        var cancelled: ScanData?
        var failure: String?
        var decoder: DecoderKind?
        var resumedAt: Int?
    }

    private func scan(_ request: ScanRequest) async -> Result {
        var result = Result()
        for await event in ShotScanner.scan(request) {
            result.events.append(event)
            switch event {
            case .started(let decoder, _, let resumedAt):
                result.decoder = decoder
                result.resumedAt = resumedAt
            case .finished(let data): result.data = data
            case .cancelled(let data): result.cancelled = data
            case .failed(let message): result.failure = message
            default: break
            }
        }
        return result
    }

    private func request(
        _ url: URL, _ method: ShotDetectionMethod = .mean, threshold: Double = 6, store: ScanCacheStore? = nil,
        observer: (any ScanFrameObserver)? = nil
    ) -> ScanRequest {
        ScanRequest(
            fileId: UUID(), url: url, method: method, threshold: threshold, ffmpeg: Self.tools, store: store,
            observer: observer)
    }

    private func checkCuts(_ data: ScanData?, threshold: Double = 6) throws {
        let data = try #require(data)
        #expect(data.complete)
        #expect(data.frameCount == Self.frameCount)
        let scenes = SceneList.scenes(from: data, threshold: threshold)
        #expect(scenes.map(\.start) == Self.cuts)
        // Y 40 in limited range is about 28 in full-range RGB.
        let first = scenes[0].colorRGB
        #expect(first.allSatisfy { abs($0 - 28) <= 4 }, "\(first)")
    }

    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func meanThroughAVFoundation() async throws {
        let clip = try await Self.makeClip("cuts.mp4", filter: Self.segments)
        let observer = RecordingObserver()
        let result = await scan(request(clip, observer: observer))
        #expect(result.failure == nil, "\(result.failure ?? "")")
        #expect(result.decoder == .avFoundation)
        try checkCuts(result.data)
        // The hook saw every frame, in order, at the decode size.
        #expect(observer.state.withLock { $0.frames } == Array(0..<Self.frameCount))
        #expect(observer.state.withLock { $0.size.map { [$0.0, $0.1] } } == [320, 180])
    }

    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func histogramThroughAVFoundation() async throws {
        let clip = try await Self.makeClip("cuts.mp4", filter: Self.segments)
        let result = await scan(request(clip, .histogram, threshold: 3))
        #expect(result.failure == nil, "\(result.failure ?? "")")
        try checkCuts(result.data, threshold: 3)
        #expect(result.data?.method == .histogram)
    }

    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func meanThroughFFmpeg() async throws {
        let clip = try await Self.makeClip("cuts.mkv", filter: Self.segments)
        let observer = RecordingObserver()
        let result = await scan(request(clip, observer: observer))
        #expect(result.failure == nil, "\(result.failure ?? "")")
        #expect(result.decoder == .ffmpeg)
        try checkCuts(result.data)
        #expect(observer.state.withLock { $0.frames.count } == Self.frameCount)
    }

    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func cancelledScanResumes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FrameSheetScans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScanCacheStore(directory: dir)
        for name in ["cuts.mp4", "cuts.mkv"] {
            let clip = try await Self.makeClip(name, filter: Self.segments)
            var first = request(clip, store: store)
            first.stopAfterFrames = 45
            let stopped = await scan(first)
            let partial = try #require(stopped.cancelled, "\(name)")
            #expect(partial.frameCount == 45 && !partial.complete)
            #expect(try store.load(first.fileId) == partial)

            var second = first
            second.stopAfterFrames = nil
            let resumed = await scan(second)
            #expect(resumed.resumedAt == 45, "\(name)")
            try checkCuts(resumed.data)
            let fresh = await scan(request(clip))
            let a = try #require(resumed.data), b = try #require(fresh.data)
            #expect(zip(a.differences, b.differences).allSatisfy { abs($0 - $1) < 0.01 }, "\(name)")
            #expect(a.colors == b.colors, "\(name)")
            #expect(try store.load(first.fileId)?.complete == true)

            // A complete cache answers without decoding.
            let cached = await scan(second)
            #expect(cached.decoder == nil)
            #expect(cached.data == a)
        }
    }

    /// A thumb requested during the scan is decoded before the scan ends:
    /// the scan closes its reader, lets the request through the gate and
    /// resumes with the same result.
    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func thumbRequestsInterleave() async throws {
        let clip = try await Self.makeClip("cuts.mp4", filter: Self.segments)
        let backend = try await DecoderRouter.open(clip, ffmpeg: Self.tools)
        let thumbDone = Locked<Int?>(nil)
        let observerBox = Locked<RecordingObserver?>(nil)
        let observer = RecordingObserver(trigger: 10) {
            Task {
                _ = try? await backend.frame(5, maxWidth: 160)
                let seen = observerBox.get()?.state.withLock { $0.frames.last }
                thumbDone.set(seen ?? -1)
            }
            // Wait until the request queues at the gate.
            for _ in 0..<2000 where !(await DecodeGate.shared.hasWaiters) {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        observerBox.set(observer)
        var req = request(clip, observer: observer)
        req.yieldCheckFrames = 4
        req.minimumRunBeforeYield = .zero
        let result = await scan(req)
        #expect(result.failure == nil, "\(result.failure ?? "")")
        try checkCuts(result.data)
        for _ in 0..<2000 where thumbDone.get() == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        let at = try #require(thumbDone.get())
        #expect(at < Self.frameCount - 1, "the thumb waited for the whole scan (done at frame \(at))")
        #expect(observer.state.withLock { $0.frames } == Array(0..<Self.frameCount))
    }

    /// A rotated track is scanned upright, as the thumbnails show it.
    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func rotatedTrackIsUpright() async throws {
        let tools = try #require(Self.tools)
        let plain = try await Self.makeClip(
            "plain.mp4", filter: "geq=lum='if(lt(X,W/2)*lt(Y,H/2),235,16)':cb=128:cr=128", frames: 10)
        let rotated = plain.deletingLastPathComponent().appending(path: "rotated.mp4")
        let remux = try await ProcessRunner.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y", "-display_rotation", "90", "-i", plain.path,
            "-c", "copy", rotated.path,
        ])
        try #require(remux.status == 0, "\(remux.stderrText)")
        let observer = RecordingObserver()
        let result = await scan(request(rotated, observer: observer))
        #expect(result.failure == nil, "\(result.failure ?? "")")
        let backend = try await DecoderRouter.open(rotated, ffmpeg: tools)
        let thumb = try await backend.frame(0, maxWidth: 720)
        #expect(observer.state.withLock { $0.size.map { [$0.0, $0.1] } } == [thumb.image.width, thumb.image.height])
        #expect(observer.state.withLock { $0.size?.1 } == 320)
        #expect(observer.state.withLock { $0.brightQuadrant } == brightestQuadrant(thumb.image))
    }

    /// Automatic IN/OUT on a clip that fades in from black after 12 frames
    /// and ends with 8 black frames.
    @Test(.enabled(if: ShotScanIntegrationTests.tools != nil)) func automaticInOut() async throws {
        let filter = "geq=lum='if(lt(N,12)+gte(N,52),16,200)':cb=128:cr=128"
        for name in ["fade.mp4", "fade.mkv"] {
            let clip = try await Self.makeClip(name, filter: filter, frames: 60)
            let points = try await AutoInOut.detect(clip, ffmpeg: Self.tools)
            #expect(points.inFrame == 12, "\(name)")
            #expect(points.outFrame == 51, "\(name)")
        }
    }
}
