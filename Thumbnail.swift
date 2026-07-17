import Foundation

// One extracted grid cell: its sample timestamp and the temp JPEG backing it.
// `hidden` is unused for now — reserved for future per-thumbnail exclusion (Phase 3a).
struct Thumbnail: Identifiable {
    let id = UUID()
    let timestamp: Double
    let imagePath: String
    var hidden: Bool = false
}
