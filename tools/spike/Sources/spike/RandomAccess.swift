import AVFoundation

/// Measurement 5: `AVAssetImageGenerator` on evenly spaced times.
func runRandom(_ args: Args) async throws {
    let path = try args.requireFile()
    let count = args.int("count", 16)
    let tolerance = args.double("tolerance") ?? 0
    let maxSide = args.int("max", 720)
    let (asset, _, info) = try await loadVideo(path)
    log("random: count=\(count) tolerance=±\(tolerance)s maximumSize=\(maxSide)")
    let times = (0..<count).map {
        CMTime(seconds: info.duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)
    }

    try await runRepeated(args.int("runs", 3)) { _ in
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let window = tolerance == 0 ? CMTime.zero : CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = window
        generator.requestedTimeToleranceAfter = window
        var images = 0
        var offsets: [Double] = []
        let start = now()
        for await result in generator.images(for: times) {
            if let actual = try? result.actualTime, (try? result.image) != nil {
                images += 1
                offsets.append(abs(actual.seconds - result.requestedTime.seconds))
            }
        }
        let wall = now() - start
        var m = Metrics()
        m.set("images", Double(images))
        m.set("wall_s", wall)
        m.set("ms_per_image", wall * 1000 / Double(max(1, images)))
        m.set("mean_offset_s", offsets.reduce(0, +) / Double(max(1, offsets.count)))
        m.set("max_offset_s", offsets.max() ?? 0)
        return m
    }
}
