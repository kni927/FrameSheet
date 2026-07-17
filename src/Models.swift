import Foundation

// MARK: - Models

struct VideoFileInfo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var duration: Double = 0
    var size: Int64 = 0
    var width: Int = 0
    var height: Int = 0
    var codec: String = ""
    var frameRate: String = ""
    var isLoaded: Bool = false

    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

struct FFProbeResult: Codable {
    struct Format: Codable {
        let duration: String?
        let size: String?
        let format_name: String?
        let format_long_name: String?
    }

    struct Stream: Codable {
        let codec_type: String
        let codec_name: String?
        let width: Int?
        let height: Int?
        let r_frame_rate: String?
        let duration: String?
    }

    let format: Format?
    let streams: [Stream]?
}
