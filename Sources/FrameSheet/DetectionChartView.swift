import FrameSheetCore
import SwiftUI

/// The detection chart (§10, key F; MoviePrint's chart under the sheet):
/// the difference per frame of the movie's stored scan, the threshold line
/// (current setting), MoviePrint's calculated threshold (k-means, display
/// only) and the cuts. Each pixel column shows the largest difference of the
/// frames it covers, so no cut disappears in the overview. Zoom with the
/// slider, scroll by dragging the chart or with the position slider; Esc or
/// F closes it.
struct DetectionChartView: View {
    @Environment(AppModel.self) private var model
    let chart: DetectionChartData
    /// Frames on screen: all of them at zoom 1.
    @State private var zoom = 1.0
    /// First frame on screen.
    @State private var start = 0.0
    @State private var dragStart: Double?
    @State private var hoverX: Double?

    /// Fewest frames the zoom shows.
    static let minVisibleFrames = 100.0

    var body: some View {
        let count = Double(chart.differences.count)
        let maxZoom = max(1, count / Self.minVisibleFrames)
        let visible = max(1, (count / zoom).rounded())
        let first = min(max(0, start), max(0, count - visible))
        let threshold = model.library.settings.shotDetectionThreshold
        let cuts = model.chartCuts(chart)
        VStack(alignment: .leading, spacing: Theme.space3) {
            header(threshold: threshold, cutSource: cuts.source, cutCount: cuts.frames.count)
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let columns = Self.columns(chart.differences, first: Int(first), count: Int(visible), width: Int(width))
                let peak = Double(columns.max() ?? 0)
                let yMax = max(1, max(peak, threshold, Double(chart.calculatedThreshold ?? 0)) * 1.1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(
                            in: &context, size: size, columns: columns, yMax: yMax, threshold: threshold,
                            cuts: cuts.frames, first: first, visible: visible)
                    }
                    .background(Theme.mantle, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    if let hoverX {
                        readout(at: hoverX, width: width, first: first, visible: visible)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStart == nil { dragStart = first }
                            let framesPerPoint = visible / width
                            start = (dragStart ?? first) - value.translation.width * framesPerPoint
                            hoverX = value.location.x
                        }
                        .onEnded { _ in
                            start = min(max(0, start), max(0, count - visible))
                            dragStart = nil
                        })
                .accessibilityElement()
                .accessibilityLabel("Difference per frame")
                .accessibilityValue("\(chart.differences.count) frames, threshold \(String(format: "%.1f", threshold))")
            }
            .frame(minHeight: 260)
            controls(count: count, maxZoom: maxZoom, visible: visible, first: first)
        }
        .padding(Theme.space4)
        .frame(minWidth: 760, idealWidth: 960, minHeight: 440, idealHeight: 520)
        .background(Theme.base)
        .foregroundStyle(Theme.text)
        .font(Theme.bodySm)
    }

    private func header(threshold: Double, cutSource: String, cutCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Detection chart")
                    .font(Theme.sectionTitle)
                Text(chart.fileName + (chart.complete ? "" : " (partial scan)"))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.space4)
            LegendItem(color: Theme.accent, text: "Difference (\(chart.method == .mean ? "mean" : "histogram"))")
            LegendItem(color: Theme.danger, text: "Threshold \(String(format: "%.1f", threshold))")
            if let calculated = chart.calculatedThreshold {
                LegendItem(color: Theme.success, text: "Calculated \(calculated)")
                    .help("k-means (k = 3) on the histogram of the differences, display only")
            }
            LegendItem(color: Theme.info, text: "\(cutCount) \(cutSource)")
            Button("Done") { model.detectionChart = nil }
                .keyboardShortcut(.cancelAction)
                .help("Close the chart (Esc)")
            // F closes it too, as it opened it.
            Button("") { model.detectionChart = nil }
                .keyboardShortcut("f", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func controls(count: Double, maxZoom: Double, visible: Double, first: Double) -> some View {
        HStack(spacing: Theme.space3) {
            Text("Zoom")
                .foregroundStyle(Theme.textMuted)
            // Logarithmic: each step of the slider doubles the zoom.
            Slider(
                value: Binding(
                    get: { log2(zoom) },
                    set: { value in
                        // Keep the middle of the view in place.
                        let middle = first + visible / 2
                        zoom = min(max(1, pow(2, value)), maxZoom)
                        let newVisible = max(1, (count / zoom).rounded())
                        start = min(max(0, middle - newVisible / 2), max(0, count - newVisible))
                    }),
                in: 0...max(0.01, log2(maxZoom)))
                .frame(width: 180)
                .help("Zoom along the frames")
            Text("Position")
                .foregroundStyle(Theme.textMuted)
            Slider(
                value: Binding(get: { first }, set: { start = $0 }),
                in: 0...max(1, count - visible))
                .disabled(zoom <= 1)
                .help("Scroll along the frames (or drag the chart)")
            Text("Frames \(Int(first))–\(Int(first + visible) - 1)")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
        }
    }

    /// Frame, difference and timecode under the pointer.
    private func readout(at x: Double, width: Double, first: Double, visible: Double) -> some View {
        let frame = min(chart.differences.count - 1, max(0, Int(first + x / width * visible)))
        let value = chart.differences[frame]
        return Text("Frame \(frame) · \(String(format: "%.2f", value)) · \(Timecode.string(frames: frame, fps: chart.fps))")
            .font(Theme.mono(12))
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, 2)
            .background(Theme.crust.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .padding(Theme.space2)
            .allowsHitTesting(false)
    }

    private func draw(
        in context: inout GraphicsContext, size: CGSize, columns: [Float], yMax: Double, threshold: Double,
        cuts: [Int], first: Double, visible: Double
    ) {
        let height = size.height
        func y(_ value: Double) -> Double { height - min(value, yMax) / yMax * height }
        func x(frame: Double) -> Double { (frame - first) / visible * size.width }
        // Cuts behind the data.
        var cutPath = Path()
        for cut in cuts where Double(cut) >= first && Double(cut) < first + visible {
            let cx = x(frame: Double(cut))
            cutPath.addRect(CGRect(x: cx, y: 0, width: 1, height: height))
        }
        context.fill(cutPath, with: .color(Theme.info.opacity(0.35)))
        // One bar per pixel column.
        let barWidth = size.width / Double(max(1, columns.count))
        var bars = Path()
        for (i, value) in columns.enumerated() where value > 0 {
            let top = y(Double(value))
            bars.addRect(CGRect(x: Double(i) * barWidth, y: top, width: max(1, barWidth), height: height - top))
        }
        context.fill(bars, with: .color(Theme.accent))
        func line(_ value: Double, _ color: Color) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(value)))
            path.addLine(to: CGPoint(x: size.width, y: y(value)))
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        if let calculated = chart.calculatedThreshold { line(Double(calculated), Theme.success) }
        line(threshold, Theme.danger)
        // The scale: the top value at the left.
        context.draw(
            Text(String(format: "%.0f", yMax)).font(Theme.mono(11)).foregroundStyle(Theme.textMuted),
            at: CGPoint(x: 4, y: 4), anchor: .topLeading)
    }

    /// The largest difference per pixel column of `count` frames from
    /// `first` (one column per frame when they are fewer than the pixels).
    static func columns(_ differences: [Float], first: Int, count: Int, width: Int) -> [Float] {
        let end = min(differences.count, first + count)
        guard first < end, width > 0 else { return [] }
        let n = end - first
        let columnCount = min(width, n)
        var columns = [Float](repeating: 0, count: columnCount)
        differences.withUnsafeBufferPointer { buffer in
            for i in first..<end {
                let c = (i - first) * columnCount / n
                if buffer[i] > columns[c] { columns[c] = buffer[i] }
            }
        }
        return columns
    }
}

private struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: Theme.space1) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(text).foregroundStyle(Theme.textMuted)
        }
        .fixedSize()
    }
}
