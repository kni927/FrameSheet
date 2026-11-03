import Foundation

// The detection chart's "calculated threshold" (§10, display only), ported
// from MoviePrint v0.2.23 (MIT, docs/licenses/MoviePrint-LICENSE):
// `calculateSceneList` (app/containers/App.js) turns the differences into a
// 256-bin histogram (`opencv.calcHist` on a CV_8UC1 Mat), runs
// `opencv.kmeans` with k = 3 on the points (bin, count), takes the center
// with the largest count and doubles its bin: `round(x) * 2 + 1`.
// `KMeans.cluster` follows OpenCV's `cv::kmeans` with KMEANS_RANDOM_CENTERS
// (random centers in the points' bounding box widened by 1 / dims on each
// side, the empty-cluster repair, the best of several attempts by
// compactness) with a seeded generator, so the result is repeatable.

public enum DetectionChart {
    /// Bins of the difference histogram.
    public static let binCount = 256

    /// Counts per bin of the differences as 8-bit values (rounded and
    /// clamped to 0–255, as the CV_8UC1 Mat stores them).
    public static func histogram(_ differences: [Float]) -> [Int] {
        var bins = [Int](repeating: 0, count: binCount)
        for value in differences {
            let v = value.isFinite ? Int(min(max(value.rounded(), 0), Float(binCount - 1))) : 0
            bins[v] += 1
        }
        return bins
    }

    /// MoviePrint's calculated threshold: k-means (k = 3) on the points
    /// (bin, count) of the histogram; the bin of the center with the most
    /// counts, `round(x) * 2 + 1`. Nil without differences.
    public static func calculatedThreshold(_ differences: [Float], seed: UInt64 = 0x5EED) -> Int? {
        guard !differences.isEmpty else { return nil }
        let points = histogram(differences).enumerated().map { KMeans.Point(x: Double($0), y: Double($1)) }
        // TermCriteria(EPS || MAX_ITER, 10, 0.1): the JavaScript `||` keeps
        // EPS alone, so OpenCV runs up to 100 iterations, epsilon 0.1.
        let result = KMeans.cluster(points, k: 3, attempts: 5, maxIterations: 100, epsilon: 0.1, seed: seed)
        guard let main = result.centers.max(by: { $0.y < $1.y }) else { return nil }
        return Int(IntervalFrames.jsRound(main.x)) * 2 + 1
    }
}

/// k-means on 2D points, after OpenCV's `cv::kmeans` (see above).
public enum KMeans {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        func distanceSquared(to other: Point) -> Double {
            let dx = x - other.x
            let dy = y - other.y
            return dx * dx + dy * dy
        }
    }

    public struct Result: Sendable, Equatable {
        public var centers: [Point]
        /// The cluster of each point.
        public var labels: [Int]
        /// Sum of the squared distances of the points to their centers.
        public var compactness: Double
    }

    /// Clusters `points` into `k` groups: `attempts` runs from random
    /// centers, each until no center moves more than `epsilon` or after
    /// `maxIterations`; the run with the lowest compactness wins.
    public static func cluster(
        _ points: [Point], k: Int, attempts: Int, maxIterations: Int, epsilon: Double, seed: UInt64
    ) -> Result {
        guard !points.isEmpty, k > 0 else { return Result(centers: [], labels: [], compactness: 0) }
        let k = min(k, points.count)
        var rng = SplitMix64(seed: seed)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        // OpenCV's generateRandomCenter: margin 1 / dims around the box.
        let margin = 0.5
        func randomCenter() -> Point {
            Point(
                x: (rng.unit() * (1 + margin * 2) - margin) * (maxX - minX) + minX,
                y: (rng.unit() * (1 + margin * 2) - margin) * (maxY - minY) + minY)
        }
        // OpenCV squares epsilon and compares squared center shifts.
        let epsilonSquared = epsilon * epsilon
        var best: Result?
        for _ in 0..<max(1, attempts) {
            var centers = (0..<k).map { _ in randomCenter() }
            var labels = assign(points, to: centers).labels
            for _ in 0..<max(2, maxIterations) {
                let moved = updatedCenters(points, labels: labels, k: k, previous: centers)
                let shift = zip(centers, moved.centers).map { $0.distanceSquared(to: $1) }.max() ?? 0
                centers = moved.centers
                labels = assign(points, to: centers).labels
                if shift <= epsilonSquared { break }
            }
            let final = assign(points, to: centers)
            if best.map({ final.compactness < $0.compactness }) ?? true {
                best = Result(centers: centers, labels: final.labels, compactness: final.compactness)
            }
        }
        return best!
    }

    /// Nearest center per point, and the compactness.
    static func assign(_ points: [Point], to centers: [Point]) -> (labels: [Int], compactness: Double) {
        var labels = [Int](repeating: 0, count: points.count)
        var compactness = 0.0
        for (i, point) in points.enumerated() {
            var nearest = 0
            var distance = Double.infinity
            for (c, center) in centers.enumerated() {
                let d = point.distanceSquared(to: center)
                if d < distance {
                    distance = d
                    nearest = c
                }
            }
            labels[i] = nearest
            compactness += distance
        }
        return (labels, compactness)
    }

    /// Means of the clusters. An empty cluster takes the point of the
    /// largest cluster farthest from that cluster's center (OpenCV's repair).
    static func updatedCenters(_ points: [Point], labels: [Int], k: Int, previous: [Point]) -> (centers: [Point], labels: [Int]) {
        var labels = labels
        var counts = [Int](repeating: 0, count: k)
        for label in labels { counts[label] += 1 }
        for empty in 0..<k where counts[empty] == 0 {
            guard let largest = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[largest] > 1 else { continue }
            var farthest = -1
            var distance = -1.0
            for (i, point) in points.enumerated() where labels[i] == largest {
                let d = point.distanceSquared(to: previous[largest])
                if d > distance {
                    distance = d
                    farthest = i
                }
            }
            labels[farthest] = empty
            counts[largest] -= 1
            counts[empty] += 1
        }
        var sums = [Point](repeating: Point(x: 0, y: 0), count: k)
        for (i, point) in points.enumerated() {
            sums[labels[i]].x += point.x
            sums[labels[i]].y += point.y
        }
        let centers = (0..<k).map { c in
            counts[c] > 0 ? Point(x: sums[c].x / Double(counts[c]), y: sums[c].y / Double(counts[c])) : previous[c]
        }
        return (centers, labels)
    }
}

/// A small seeded generator (SplitMix64), so k-means is repeatable.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
