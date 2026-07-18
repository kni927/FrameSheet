import Foundation

// One extracted grid cell: its sample timestamp and the temp JPEG backing it.
// `timestamp`/`imagePath` are mutable for per-cell nudging (Phase 3a Stage D);
// `hidden` marks cells excluded from export (Stage B).
struct Thumbnail: Identifiable {
    let id = UUID()
    var timestamp: Double
    var imagePath: String
    var hidden: Bool = false
}
