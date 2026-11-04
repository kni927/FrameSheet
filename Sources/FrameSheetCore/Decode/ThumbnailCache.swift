import CoreGraphics
import Foundation
import Synchronization

/// Decoded display-size thumbnails in memory, limited by their pixel bytes
/// (§6: default 256 MB). Least recently used images go first once the limit
/// is passed, and only then: NSCache, used before, also dropped entries far
/// below its limit when other apps needed memory, and every drop showed as
/// a redraw when the user went back to a sheet (T04b).
public final class ThumbnailCache: Sendable {
    private struct Entry {
        let image: CGImage
        let cost: Int
        /// Higher is more recently used.
        var lastUse: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var totalCost = 0
        var limit = 0
        var clock: UInt64 = 0

        mutating func tick() -> UInt64 {
            clock += 1
            return clock
        }

        /// Drops the least recently used entries until the total fits.
        mutating func trim() {
            while totalCost > limit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                totalCost -= oldest.value.cost
                entries[oldest.key] = nil
            }
        }
    }

    private let state = Mutex(State())

    public init(limitMB: Int = Defaults.thumbnailCacheMB) {
        setLimit(megabytes: limitMB)
    }

    public func setLimit(megabytes: Int) {
        state.withLock { state in
            state.limit = max(1, megabytes) * 1024 * 1024
            state.trim()
        }
    }

    public var limitBytes: Int { state.withLock { $0.limit } }

    /// Pixel bytes of the cached images.
    public var totalBytes: Int { state.withLock { $0.totalCost } }

    private static func key(_ file: UUID, _ frame: Int, _ width: Int) -> String {
        "\(file.uuidString)/\(frame)/\(width)"
    }

    public func image(file: UUID, frame: Int, width: Int) -> CGImage? {
        state.withLock { state in
            let key = Self.key(file, frame, width)
            guard state.entries[key] != nil else { return nil }
            state.entries[key]!.lastUse = state.tick()
            return state.entries[key]!.image
        }
    }

    public func insert(_ image: CGImage, file: UUID, frame: Int, width: Int) {
        let cost = Self.cost(of: image)
        state.withLock { state in
            let key = Self.key(file, frame, width)
            if let old = state.entries[key] { state.totalCost -= old.cost }
            state.entries[key] = Entry(image: image, cost: cost, lastUse: state.tick())
            state.totalCost += cost
            state.trim()
        }
    }

    /// Drops one image, if cached.
    public func remove(file: UUID, frame: Int, width: Int) {
        state.withLock { state in
            if let old = state.entries.removeValue(forKey: Self.key(file, frame, width)) {
                state.totalCost -= old.cost
            }
        }
    }

    public func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.totalCost = 0
        }
    }

    static func cost(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}

/// Pixel width window thumbs are decoded and cached at: the size they are
/// drawn at, not always the largest. A faces sheet of 400 thumbs at 640 px
/// (1920 × 800 film: 640 × 267 × 4 bytes each) needed 273 MB and did not fit
/// the default 256 MB cache, so going back to it redrew it; drawn at its
/// grid size (about 256 px wide in a 20-column grid) it takes 44 MB.
public enum ThumbnailWidth {
    /// Widths go up in steps, so nearby sizes share cache entries.
    public static let step = 128
    /// The widest thumb: enough for a 4-column grid on a Retina display.
    public static let maximum = 640

    /// The width for a thumb drawn `points` wide at `scale` pixels per
    /// point: rounded up to a step, at least one step, at most `maximum`,
    /// and no wider than the movie (decoders never enlarge).
    public static func decodeWidth(points: Double, scale: Double, movieWidth: Int) -> Int {
        let pixels = max(0, points) * max(1, scale)
        let stepped = max(1, Int((pixels / Double(step)).rounded(.up))) * step
        let width = min(maximum, stepped)
        return movieWidth > 0 ? min(width, movieWidth) : width
    }

    /// The width for the thumbs of a grid of `thumbCount` cells in
    /// `columns` columns laid out in a container of the given size (points)
    /// at `zoom`.
    public static func gridDecodeWidth(
        file: MovieFile, columns: Int, thumbCount: Int, settings: Settings, containerWidth: Double,
        containerHeight: Double, zoom: Double, scale: Double
    ) -> Int {
        guard containerWidth > 0, containerHeight > 0 else { return min(maximum, max(1, file.frameSize.width)) }
        let geometry = GridGeometry(.init(
            file: file, columnCount: columns, thumbCount: thumbCount, settings: settings,
            containerWidth: containerWidth, containerHeight: containerHeight, zoom: zoom))
        return decodeWidth(points: geometry.thumbWidth, scale: scale, movieWidth: file.frameSize.width)
    }

    /// The width for a faces sheet of `thumbCount` thumbs in an optimized
    /// grid (as Add faces sheet lays it out) at zoom 1.
    public static func facesSheetDecodeWidth(
        file: MovieFile, thumbCount: Int, settings: Settings, containerWidth: Double, containerHeight: Double,
        scale: Double
    ) -> Int {
        let count = max(1, thumbCount)
        return gridDecodeWidth(
            file: file, columns: GridLayout.optimizedColumns(thumbCount: count), thumbCount: count,
            settings: settings, containerWidth: containerWidth, containerHeight: containerHeight, zoom: 1,
            scale: scale)
    }
}
