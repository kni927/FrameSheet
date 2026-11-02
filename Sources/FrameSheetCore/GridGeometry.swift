import CoreGraphics
import Foundation

// Grid-view part of MoviePrint v0.2.23 `getScaleValueObject`
// (app/utils/getScaleValueObject.js, MIT, docs/licenses/MoviePrint-LICENSE).
// Player, scrub, paper and timeline values are left for later TASKs.

public struct GridGeometry: Equatable, Sendable {
    public struct Input: Sendable {
        public var movieWidth: Double
        public var movieHeight: Double
        /// Height / width override (transform); nil uses the movie's.
        public var aspectRatioInv: Double?
        public var columnCount: Int
        public var thumbCount: Int
        public var containerWidth: Double
        /// Very large when the container height should not limit the fit
        /// (MoviePrint's default of 99999).
        public var containerHeight: Double
        public var zoom: Double
        public var marginRatio: Double
        public var showHeader: Bool
        public var showPathInHeader: Bool
        public var showDetailsInHeader: Bool
        public var showTimelineInHeader: Bool
        public var roundedCorners: Bool

        public init(
            movieWidth: Double, movieHeight: Double, aspectRatioInv: Double? = nil,
            columnCount: Int, thumbCount: Int, containerWidth: Double,
            containerHeight: Double = 99999, zoom: Double = 1, marginRatio: Double = 0.02,
            showHeader: Bool = false, showPathInHeader: Bool = true,
            showDetailsInHeader: Bool = true, showTimelineInHeader: Bool = true,
            roundedCorners: Bool = true
        ) {
            self.movieWidth = movieWidth
            self.movieHeight = movieHeight
            self.aspectRatioInv = aspectRatioInv
            self.columnCount = columnCount
            self.thumbCount = thumbCount
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.zoom = zoom
            self.marginRatio = marginRatio
            self.showHeader = showHeader
            self.showPathInHeader = showPathInHeader
            self.showDetailsInHeader = showDetailsInHeader
            self.showTimelineInHeader = showTimelineInHeader
            self.roundedCorners = roundedCorners
        }
    }

    // Hidden constants (§5.1).
    public static let thumbnailScale = 0.25
    public static let borderRadiusRatio = 0.04
    public static let headerHeightRatio = 0.25
    /// MoviePrint `DEFAULT_MIN_MOVIEPRINTWIDTH_MARGIN`.
    public static let minPrintWidthMargin = 10.0
    /// Zoom steps (MoviePrint `SCALE_VALUE_ARRAY`); 1 is the default.
    public static let zoomSteps = [0.25, 0.33, 0.5, 0.75, 1, 2, 3, 4, 5, 6, 7, 8]

    public let columnCount: Int
    public let rowCount: Int
    public let aspectRatioInv: Double
    /// Fit scale × zoom applied to the unscaled print.
    public let scale: Double
    public let thumbWidth: Double
    public let thumbHeight: Double
    public let thumbMargin: Double
    public let borderRadius: Double
    public let headerHeight: Double
    public let printWidth: Double
    public let printHeight: Double

    public init(_ input: Input) {
        let movieWidth = input.movieWidth > 0 ? input.movieWidth : 1920
        let movieHeight = input.movieHeight > 0 ? input.movieHeight : 1080
        let ratioInv = input.aspectRatioInv ?? movieHeight / movieWidth
        let columns = max(1, input.columnCount)
        let rows = Int((Double(input.thumbCount) / Double(columns)).rounded(.up))

        let headerMultiplier = 1 + Double(
            (input.showPathInHeader ? 1 : 0) + (input.showDetailsInHeader ? 1 : 0)
                + (input.showTimelineInHeader ? 1 : 0)) / 3
        let headerHeight = input.showHeader
            ? movieHeight * Self.headerHeightRatio * headerMultiplier * Self.thumbnailScale : 0
        let thumbWidth = movieWidth * Self.thumbnailScale
        let thumbMargin = movieWidth * input.marginRatio * Self.thumbnailScale
        let borderRadius = input.roundedCorners
            ? movieWidth * Self.borderRadiusRatio * Self.thumbnailScale : 0
        let cellWidth = thumbWidth + thumbMargin * 2
        let cellHeight = thumbWidth * ratioInv + thumbMargin * 2
        let originalWidth = Double(columns) * cellWidth + thumbMargin
        let originalHeight = headerHeight + thumbMargin * 2 + Double(rows) * cellHeight
        let printRatioInv = originalHeight / originalWidth

        let fit = min(input.containerWidth / originalWidth, input.containerHeight / originalHeight)
        let scale = max(0, fit) * input.zoom

        columnCount = columns
        rowCount = rows
        aspectRatioInv = ratioInv
        self.scale = scale
        self.thumbWidth = thumbWidth * scale
        self.thumbHeight = thumbWidth * ratioInv * scale
        self.thumbMargin = thumbMargin * scale
        self.borderRadius = borderRadius * scale
        self.headerHeight = headerHeight * scale
        printWidth = originalWidth * scale + Self.minPrintWidthMargin
        printHeight = printWidth * printRatioInv
    }

    /// Frame of the thumb at `index` (raster order) inside the print, origin
    /// top left. MoviePrint lays thumbs out as inline blocks with
    /// `thumbMargin` on every side inside a print padded by half a margin
    /// left and right and a full margin top and bottom.
    public func thumbFrame(at index: Int) -> CGRect {
        let column = index % columnCount
        let row = index / columnCount
        let x = thumbMargin / 2 + Double(column) * (thumbWidth + thumbMargin * 2) + thumbMargin
        let y = headerHeight + thumbMargin + Double(row) * (thumbHeight + thumbMargin * 2) + thumbMargin
        return CGRect(x: x, y: y, width: thumbWidth, height: thumbHeight)
    }
}
