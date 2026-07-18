import SwiftUI
import Foundation
import AppKit

// Parameter bundle for the renderer. Per-thumbnail timestamps live on
// `Thumbnail` itself (resolved by the caller before rendering), not here.
struct GenerationParams {
    let cols: Int, rows: Int
    let imageWidth: Int, spacing: Int
    let video: VideoFileInfo
    let showHeader: Bool, showTimestamps: Bool
    let useCustomHeader: Bool, customHeaderTemplate: String
    let bgColor: Color, textColor: Color
    let fontName: String, customFontPath: String
    let tsPosition: String
    var cornerRadius: Int = 0
}

// Geometry + header text shared by the full-sheet composite (export) and
// the per-cell display images (Phase 3a grid). One source of truth so the
// on-screen grid and the exported sheet cannot drift apart.
struct SheetMetrics {
    let cellW: Int
    let cellH: Int
    let headerLines: [String]
    let headerH: Int
}

// CoreGraphics / AppKit composite renderer. Standalone — no dependency on
// AppState or any View type; AppState calls into this.
enum ContactSheetRenderer {

    static func metrics(for p: GenerationParams) -> SheetMetrics {
        let cols    = p.cols
        let spacing = p.spacing
        let cellW   = max(10, (p.imageWidth - (cols - 1) * spacing) / cols)
        let ar      = p.video.width > 0 ? Double(p.video.height) / Double(p.video.width) : 9.0 / 16.0
        let cellH   = max(1, Int(Double(cellW) * ar))

        let fontSize: CGFloat   = 14
        let headerMargin: CGFloat = 10
        var headerLines: [String] = []
        if p.showHeader {
            if p.useCustomHeader && !p.customHeaderTemplate.isEmpty {
                var t = p.customHeaderTemplate
                t = t.replacingOccurrences(of: "{{filename}}",     with: p.video.name)
                t = t.replacingOccurrences(of: "{{size}}",         with: p.video.formattedSize)
                t = t.replacingOccurrences(of: "{{duration}}",     with: p.video.formattedDuration)
                t = t.replacingOccurrences(of: "{{sample_width}}", with: "\(p.imageWidth)")
                t = t.replacingOccurrences(of: "{{sample_height}}",with: "\(p.rows * cellH + max(0, p.rows - 1) * spacing)")
                t = t.replacingOccurrences(of: "{{video_codec}}",  with: p.video.codec)
                t = t.replacingOccurrences(of: "{{frame_rate}}",   with: p.video.frameRate)
                headerLines = t.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            } else {
                headerLines = [
                    p.video.name,
                    "File size: \(p.video.formattedSize)",
                    "Duration: \(p.video.formattedDuration)",
                    "Dimensions: \(p.video.width)x\(p.video.height)"
                ]
            }
        }
        let lineH: CGFloat = fontSize * 1.45
        let headerH = headerLines.isEmpty ? 0 : Int(2 * headerMargin + CGFloat(headerLines.count) * lineH)

        return SheetMetrics(cellW: cellW, cellH: cellH, headerLines: headerLines, headerH: headerH)
    }

    private static func resolveFontName(_ fontName: String) -> String {
        switch fontName {
        case "Helvetica": return "Helvetica"
        case "Times":     return "TimesNewRomanPSMT"
        default:          return "HiraginoSans-W3"
        }
    }

    private static func timestampAttributes(params p: GenerationParams, cellW: Int) -> [NSAttributedString.Key: Any] {
        let psName = resolveFontName(p.fontName)
        let tsFontSize: CGFloat = max(8, CGFloat(cellW) * 0.065)
        let tsFont = NSFont(name: psName, size: tsFontSize) ?? NSFont.systemFont(ofSize: tsFontSize)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        return [.font: tsFont, .foregroundColor: NSColor(p.textColor), .shadow: shadow]
    }

    // Draw one cell (image with optional rounded-corner clip, plus timestamp
    // overlay) into the CURRENT NSGraphicsContext at destRect. Shared by the
    // full-sheet composite and the per-cell display renderer — the single
    // source of truth for cell appearance.
    private static func drawCell(
        _ thumb: Thumbnail,
        in destRect: NSRect,
        params p: GenerationParams,
        tsAttrs: [NSAttributedString.Key: Any]
    ) {
        NSGraphicsContext.current?.saveGraphicsState()
        if p.cornerRadius > 0 {
            NSBezierPath(roundedRect: destRect,
                         xRadius: CGFloat(p.cornerRadius),
                         yRadius: CGFloat(p.cornerRadius)).addClip()
        }
        if let img = NSImage(contentsOfFile: thumb.imagePath) {
            img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor(white: 0.12, alpha: 1).setFill()
            destRect.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        if p.showTimestamps {
            let attrTS  = NSAttributedString(string: formatTimestamp(thumb.timestamp), attributes: tsAttrs)
            let tsSize  = attrTS.size()
            let pad: CGFloat = 4
            let x = destRect.origin.x, y = destRect.origin.y
            let cellW = destRect.width, cellH = destRect.height
            let tsX: CGFloat
            let tsY: CGFloat
            switch p.tsPosition {
            case "top-left":
                tsX = x + pad;                       tsY = y + cellH - tsSize.height - pad
            case "top-right":
                tsX = x + cellW - tsSize.width - pad; tsY = y + cellH - tsSize.height - pad
            case "bottom-left":
                tsX = x + pad;                       tsY = y + pad
            default: // bottom-right
                tsX = x + cellW - tsSize.width - pad; tsY = y + pad
            }
            attrTS.draw(at: CGPoint(x: tsX, y: tsY))
        }
    }

    static func render(thumbnails: [Thumbnail], params p: GenerationParams) -> NSImage? {
        let m = metrics(for: p)
        let cols    = p.cols
        let spacing = p.spacing
        let cellW   = m.cellW
        let cellH   = m.cellH
        let rows    = p.rows
        let headerH = m.headerH
        let fontSize: CGFloat = 14
        let headerMargin: CGFloat = 10
        let lineH: CGFloat = fontSize * 1.45

        let totalW = p.imageWidth
        let totalH = headerH + rows * cellH + max(0, rows - 1) * spacing
        guard totalW > 0 && totalH > 0 else { return nil }

        // Create bitmap CGContext
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: totalW, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Wrap in NSGraphicsContext so AppKit drawing works (origin = bottom-left)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // Background fill
        NSColor(p.bgColor).setFill()
        NSRect(x: 0, y: 0, width: totalW, height: totalH).fill()

        // Draw header
        let psName = resolveFontName(p.fontName)
        let nsFont = NSFont(name: psName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: nsFont, .foregroundColor: NSColor(p.textColor)]
        for (i, line) in m.headerLines.enumerated() {
            let y = CGFloat(totalH) - headerMargin - CGFloat(i + 1) * lineH
            NSAttributedString(string: line, attributes: headerAttrs).draw(at: CGPoint(x: headerMargin, y: y))
        }

        // Draw thumbnails + timestamps
        let tsAttrs = timestampAttributes(params: p, cellW: cellW)
        for i in 0..<min(thumbnails.count, rows * cols) {
            let col = i % cols
            let row = i / cols
            let x   = col * (cellW + spacing)
            // Y from bottom-left origin: top row is highest Y
            let y   = totalH - headerH - (row + 1) * cellH - row * spacing
            let destRect = NSRect(x: x, y: y, width: cellW, height: cellH)
            drawCell(thumbnails[i], in: destRect, params: p, tsAttrs: tsAttrs)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: totalW, height: totalH))
    }

    // Render one cell as a standalone image (transparent background — the
    // grid's background color shows through rounded corners), for the
    // Phase 3a addressable-grid display. Same drawing code as the sheet.
    static func renderCellImage(_ thumb: Thumbnail, params p: GenerationParams) -> NSImage? {
        let m = metrics(for: p)
        guard m.cellW > 0 && m.cellH > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: m.cellW, height: m.cellH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let tsAttrs = timestampAttributes(params: p, cellW: m.cellW)
        drawCell(thumb, in: NSRect(x: 0, y: 0, width: m.cellW, height: m.cellH), params: p, tsAttrs: tsAttrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: m.cellW, height: m.cellH))
    }

    // Render the header block as a standalone strip (background color +
    // header text), for the Phase 3a grid display. Returns nil when the
    // header is disabled/empty.
    static func renderHeaderImage(params p: GenerationParams) -> NSImage? {
        let m = metrics(for: p)
        guard m.headerH > 0, p.imageWidth > 0 else { return nil }
        let fontSize: CGFloat = 14
        let headerMargin: CGFloat = 10
        let lineH: CGFloat = fontSize * 1.45
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: p.imageWidth, height: m.headerH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor(p.bgColor).setFill()
        NSRect(x: 0, y: 0, width: p.imageWidth, height: m.headerH).fill()
        let psName = resolveFontName(p.fontName)
        let nsFont = NSFont(name: psName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: nsFont, .foregroundColor: NSColor(p.textColor)]
        for (i, line) in m.headerLines.enumerated() {
            let y = CGFloat(m.headerH) - headerMargin - CGFloat(i + 1) * lineH
            NSAttributedString(string: line, attributes: headerAttrs).draw(at: CGPoint(x: headerMargin, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: p.imageWidth, height: m.headerH))
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let s   = max(0, seconds)
        let h   = Int(s) / 3600
        let m   = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    static func parseTimestamps(_ text: String) -> [Double] {
        text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
            .compactMap { part -> Double? in
                let s = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { return nil }
                let c = s.components(separatedBy: ":")
                switch c.count {
                case 2:
                    if let min = Double(c[0]), let sec = Double(c[1]) { return min * 60 + sec }
                case 3:
                    if let h = Double(c[0]), let min = Double(c[1]), let sec = Double(c[2]) { return h * 3600 + min * 60 + sec }
                default: break
                }
                return Double(s)
            }
    }
}
