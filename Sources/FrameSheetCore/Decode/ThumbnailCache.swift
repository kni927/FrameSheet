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
