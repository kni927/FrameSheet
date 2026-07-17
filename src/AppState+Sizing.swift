import SwiftUI
import Foundation

extension AppState {
    // Calculated height of the generated contact sheet image
    var estimatedHeight: Int {
        guard let video = selectedVideo, video.width > 0, video.height > 0 else { return 0 }

        let colCount = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let totalWidth = CGFloat(imageWidth)
        let spacing = CGFloat(gridSpacing)

        let desiredFrameWidth = (totalWidth - (colCount - 1) * spacing) / colCount
        let aspectRatio = CGFloat(video.height) / CGFloat(video.width)
        let desiredFrameHeight = desiredFrameWidth * aspectRatio

        let gridHeight = rowCount * (desiredFrameHeight + spacing) - spacing

        var headerHeight: CGFloat = 0
        if showHeader {
            let lineSpacingCoefficient: CGFloat = 1.2
            let fontSize: CGFloat = 16
            let margin: CGFloat = 10
            let headerLineHeight = CGFloat(Int(fontSize * lineSpacingCoefficient))

            var estimatedLines: CGFloat = 4
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let lines = customHeaderTemplate.components(separatedBy: .newlines)
                estimatedLines = CGFloat(max(1, lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
            }

            headerHeight = 2 * margin + estimatedLines * headerLineHeight
        }

        return Int(gridHeight + headerHeight)
    }

    // Min and Max height bounds for the height slider
    var minHeight: Double {
        calculateHeightForWidth(600)
    }

    var maxHeight: Double {
        calculateHeightForWidth(3200)
    }

    func calculateHeightForWidth(_ w: Int) -> Double {
        guard let video = selectedVideo, video.width > 0, video.height > 0 else { return 800 }

        let colCount = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let totalWidth = CGFloat(w)
        let spacing = CGFloat(gridSpacing)

        let desiredFrameWidth = (totalWidth - (colCount - 1) * spacing) / colCount
        let aspectRatio = CGFloat(video.height) / CGFloat(video.width)
        let desiredFrameHeight = desiredFrameWidth * aspectRatio

        let gridHeight = rowCount * (desiredFrameHeight + spacing) - spacing

        var headerHeight: CGFloat = 0
        if showHeader {
            let lineSpacingCoefficient: CGFloat = 1.2
            let fontSize: CGFloat = 16
            let margin: CGFloat = 10
            let headerLineHeight = CGFloat(Int(fontSize * lineSpacingCoefficient))

            var estimatedLines: CGFloat = 4
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let lines = customHeaderTemplate.components(separatedBy: .newlines)
                estimatedLines = CGFloat(max(1, lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
            }

            headerHeight = 2 * margin + estimatedLines * headerLineHeight
        }

        return Double(gridHeight + headerHeight)
    }

    // Reverse calculates and updates imageWidth from a target totalHeight
    func updateWidthFromHeight(_ targetHeight: Int) {
        guard let video = selectedVideo, video.width > 0, video.height > 0 else { return }

        let colCount = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let spacing = CGFloat(gridSpacing)
        let aspectRatio = CGFloat(video.height) / CGFloat(video.width)

        var headerHeight: CGFloat = 0
        if showHeader {
            let lineSpacingCoefficient: CGFloat = 1.2
            let fontSize: CGFloat = 16
            let margin: CGFloat = 10
            let headerLineHeight = CGFloat(Int(fontSize * lineSpacingCoefficient))

            var estimatedLines: CGFloat = 4
            if useCustomHeaderTemplate && !customHeaderTemplate.isEmpty {
                let lines = customHeaderTemplate.components(separatedBy: .newlines)
                estimatedLines = CGFloat(max(1, lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
            }

            headerHeight = 2 * margin + estimatedLines * headerLineHeight
        }

        let targetGridHeight = CGFloat(targetHeight) - headerHeight
        let h_f = (targetGridHeight + spacing) / rowCount - spacing
        let w_f = h_f / aspectRatio
        let targetWidth = colCount * w_f + (colCount - 1) * spacing

        let finalWidth = max(600, min(3200, Int(round(targetWidth))))

        if self.imageWidth != finalWidth {
            self.imageWidth = finalWidth
        }
    }

    // Fit zoom scale to container size (both width and height) to fit screen
    func fitToScreen() {
        guard let img = previewImage else { return }

        // Image has padding(20) in CanvasView, which adds 40px to both width and height.
        // Also add a safety margin of 20px to avoid scrollbars triggering due to rounding or minor layouts.
        let containerW = containerWidth - 60

        // Calculate vertical offset dynamically depending on visible UI elements
        var offsetH: CGFloat = 30 + 40 + 20 // Base padding + Image padding(40) + Safety margin(20)
        if selectedVideo != nil {
            offsetH += 45 // Video info card height
        }
        if previewImage != nil && !isGenerating {
            offsetH += 45 // Copy/Save action bar height
        }

        let containerH = containerHeight - offsetH
        let imgW = CGFloat(imageWidth)
        let imgH = imgW * img.aspectRatio

        let scaleW = containerW / imgW
        let scaleH = containerH / imgH

        zoomScale = min(1.0, max(0.1, min(scaleW, scaleH)))
    }
}
