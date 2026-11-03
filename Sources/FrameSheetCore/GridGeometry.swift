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
        /// Margin between columns and at the left and right edges.
        public var marginRatioHorizontal: Double
        /// Margin between rows and at the top and bottom edges.
        public var marginRatioVertical: Double
        public var showHeader: Bool
        public var showPathInHeader: Bool
        public var showDetailsInHeader: Bool
        public var showTimelineInHeader: Bool
        /// Corner radius as a fraction of the movie width at thumbnail
        /// scale, i.e. of the thumb width; 0 gives square corners.
        public var borderRadiusRatio: Double

        /// One margin ratio for both directions.
        public init(
            movieWidth: Double, movieHeight: Double, aspectRatioInv: Double? = nil,
            columnCount: Int, thumbCount: Int, containerWidth: Double,
            containerHeight: Double = 99999, zoom: Double = 1, marginRatio: Double = 0.02,
            showHeader: Bool = false, showPathInHeader: Bool = true,
            showDetailsInHeader: Bool = true, showTimelineInHeader: Bool = true,
            borderRadiusRatio: Double = GridGeometry.borderRadiusRatio
        ) {
            self.init(
                movieWidth: movieWidth, movieHeight: movieHeight, aspectRatioInv: aspectRatioInv,
                columnCount: columnCount, thumbCount: thumbCount, containerWidth: containerWidth,
                containerHeight: containerHeight, zoom: zoom, marginRatioHorizontal: marginRatio,
                marginRatioVertical: marginRatio, showHeader: showHeader,
                showPathInHeader: showPathInHeader, showDetailsInHeader: showDetailsInHeader,
                showTimelineInHeader: showTimelineInHeader, borderRadiusRatio: borderRadiusRatio)
        }

        public init(
            movieWidth: Double, movieHeight: Double, aspectRatioInv: Double? = nil,
            columnCount: Int, thumbCount: Int, containerWidth: Double,
            containerHeight: Double = 99999, zoom: Double = 1, marginRatioHorizontal: Double,
            marginRatioVertical: Double, showHeader: Bool = false, showPathInHeader: Bool = true,
            showDetailsInHeader: Bool = true, showTimelineInHeader: Bool = true,
            borderRadiusRatio: Double = GridGeometry.borderRadiusRatio
        ) {
            self.movieWidth = movieWidth
            self.movieHeight = movieHeight
            self.aspectRatioInv = aspectRatioInv
            self.columnCount = columnCount
            self.thumbCount = thumbCount
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.zoom = zoom
            self.marginRatioHorizontal = marginRatioHorizontal
            self.marginRatioVertical = marginRatioVertical
            self.showHeader = showHeader
            self.showPathInHeader = showPathInHeader
            self.showDetailsInHeader = showDetailsInHeader
            self.showTimelineInHeader = showTimelineInHeader
            self.borderRadiusRatio = borderRadiusRatio
        }
    }

    // Hidden constants (§5.1).
    public static let thumbnailScale = 0.25
    /// Default corner radius ratio (MoviePrint).
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
    /// Scale (before zoom) at which the print's width fills the container.
    public let fitWidthScale: Double
    /// Scale (before zoom) at which the print's height fills the container.
    public let fitHeightScale: Double
    public let thumbWidth: Double
    public let thumbHeight: Double
    /// Horizontal margin (between columns, left and right).
    public let thumbMargin: Double
    /// Vertical margin (between rows, top and bottom).
    public let thumbMarginVertical: Double
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
        let thumbMargin = movieWidth * input.marginRatioHorizontal * Self.thumbnailScale
        let marginVertical = movieWidth * input.marginRatioVertical * Self.thumbnailScale
        let borderRadius = movieWidth * max(0, input.borderRadiusRatio) * Self.thumbnailScale
        let cellWidth = thumbWidth + thumbMargin * 2
        let cellHeight = thumbWidth * ratioInv + marginVertical * 2
        let originalWidth = Double(columns) * cellWidth + thumbMargin
        let originalHeight = headerHeight + marginVertical * 2 + Double(rows) * cellHeight
        let printRatioInv = originalHeight / originalWidth

        let fitWidth = max(0, input.containerWidth / originalWidth)
        let fitHeight = max(0, input.containerHeight / originalHeight)
        let scale = min(fitWidth, fitHeight) * input.zoom

        columnCount = columns
        rowCount = rows
        aspectRatioInv = ratioInv
        self.scale = scale
        fitWidthScale = fitWidth
        fitHeightScale = fitHeight
        self.thumbWidth = thumbWidth * scale
        self.thumbHeight = thumbWidth * ratioInv * scale
        self.thumbMargin = thumbMargin * scale
        thumbMarginVertical = marginVertical * scale
        self.borderRadius = borderRadius * scale
        self.headerHeight = headerHeight * scale
        printWidth = originalWidth * scale + Self.minPrintWidthMargin
        printHeight = printWidth * printRatioInv
    }

    /// Fit scale (zoom 1): the smaller of the two.
    public var fitScale: Double { min(fitWidthScale, fitHeightScale) }

    /// Zoom at which the print's height fills the container (Fit height);
    /// above 1 for a width-limited print, which then scrolls sideways.
    public var zoomFillingHeight: Double { Self.zoom(filling: fitHeightScale, fit: fitScale) }

    /// Zoom at which the print's width fills the container (Fit width).
    public var zoomFillingWidth: Double { Self.zoom(filling: fitWidthScale, fit: fitScale) }

    /// At this zoom the print leaves space above and below (Fit height
    /// would grow it).
    public var hasSpaceAboveAndBelow: Bool { scale < fitHeightScale * (1 - Self.fillTolerance) }

    /// At this zoom the print leaves space at the sides (Fit width would
    /// grow it).
    public var hasSpaceAtSides: Bool { scale < fitWidthScale * (1 - Self.fillTolerance) }

    /// Relative slack below which a print counts as filling a direction.
    static let fillTolerance = 0.005

    /// Zoom relative to the fit scale that reaches `fill`.
    public static func zoom(filling fill: Double, fit: Double) -> Double {
        fit > 0 ? fill / fit : 1
    }

    /// Frame of the thumb at `index` (raster order) inside the print, origin
    /// top left. MoviePrint lays thumbs out as inline blocks with
    /// `thumbMargin` on every side inside a print padded by half a margin
    /// left and right and a full margin top and bottom; here the left and
    /// right sides use the horizontal margin, the top and bottom the
    /// vertical one.
    public func thumbFrame(at index: Int) -> CGRect {
        let column = index % columnCount
        let row = index / columnCount
        let x = thumbMargin / 2 + Double(column) * (thumbWidth + thumbMargin * 2) + thumbMargin
        let y = headerHeight + thumbMarginVertical + Double(row) * (thumbHeight + thumbMarginVertical * 2)
            + thumbMarginVertical
        return CGRect(x: x, y: y, width: thumbWidth, height: thumbHeight)
    }
}
