import CoreGraphics
import Foundation

/// Decoded display-size thumbnails in memory, limited by their pixel bytes
/// (§6: default 256 MB). NSCache evicts on its own when the limit or memory
/// pressure is reached.
public final class ThumbnailCache: @unchecked Sendable {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    // NSCache is thread-safe.
    private let cache = NSCache<NSString, Entry>()

    public init(limitMB: Int = Defaults.thumbnailCacheMB) {
        setLimit(megabytes: limitMB)
    }

    public func setLimit(megabytes: Int) {
        cache.totalCostLimit = max(1, megabytes) * 1024 * 1024
    }

    public var limitBytes: Int { cache.totalCostLimit }

    private static func key(_ file: UUID, _ frame: Int, _ width: Int) -> NSString {
        "\(file.uuidString)/\(frame)/\(width)" as NSString
    }

    public func image(file: UUID, frame: Int, width: Int) -> CGImage? {
        cache.object(forKey: Self.key(file, frame, width))?.image
    }

    public func insert(_ image: CGImage, file: UUID, frame: Int, width: Int) {
        cache.setObject(Entry(image), forKey: Self.key(file, frame, width), cost: Self.cost(of: image))
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    static func cost(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}
