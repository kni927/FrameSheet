import AppKit
import FrameSheetCore
import SwiftUI

// The kni Design System, Mocha (dark) theme: colour, type, spacing and radius
// tokens. Colours are Catppuccin Mocha (MIT, docs/licenses/Catppuccin-LICENSE);
// fonts are IBM Plex Sans and Plex Mono (OFL 1.1, docs/licenses/IBM-Plex-LICENSE),
// bundled under Contents/Resources/Fonts and registered through
// ATSApplicationFontsPath. Views use the token names, not the palette.
enum Theme {
    // MARK: Colour tokens

    /// Main area background.
    static let base = Palette.base
    /// Cards and panels on base.
    static let mantle = Palette.mantle
    /// Sidebars, toolbars; the deepest ground.
    static let crust = Palette.crust
    /// Inputs, chips, secondary buttons, selected rows.
    static let surface = Palette.surface0
    static let surfaceHover = Palette.surface1
    /// 1 pt dividers and card outlines (decorative only).
    static let border = Palette.surface1
    /// Edges of controls (3:1 on base and mantle).
    static let borderControl = Palette.overlay0
    static let text = Palette.text
    static let textMuted = Palette.subtext0
    /// Brand fill (mauve), used sparingly; text on it is `onAccent`.
    static let accent = Palette.mauve
    static let onAccent = Palette.crust
    /// Accent-coloured text and icons on base, mantle and crust.
    static let accentInk = Palette.mauve
    static let link = Palette.blue
    static let focus = Palette.lavender
    static let success = Palette.green
    static let warning = Palette.yellow
    static let danger = Palette.red
    static let info = Palette.sapphire

    // MARK: Type styles

    // Font.custom falls back through the system cascade list, so Japanese
    // text (file names) renders in Hiragino Sans, as the design system's
    // sans and mono families specify.
    private static let sansRegular = "IBMPlexSans"
    private static let sansMedium = "IBMPlexSans-Medm"
    private static let sansSemiBold = "IBMPlexSans-SmBld"
    private static let monoRegular = "IBMPlexMono"
    private static let monoMedium = "IBMPlexMono-Medm"

    /// Labels and metadata, 12/500, in textMuted.
    static let caption = Font.custom(sansMedium, size: 12)
    /// Dense lists and controls, 13/400.
    static let bodySm = Font.custom(sansRegular, size: 13)
    static let body = Font.custom(sansRegular, size: 15)
    static let heading2 = Font.custom(sansSemiBold, size: 19)
    static let heading1 = Font.custom(sansSemiBold, size: 24)
    /// Code, paths and numbers that line up, 13/400.
    static let code = Font.custom(monoRegular, size: 13)

    /// Section titles in the sidebars: caption size at the medium weight,
    /// in `text`.
    static let label = Font.custom(sansMedium, size: 13)
    static func sans(_ size: Double, medium: Bool = false) -> Font {
        .custom(medium ? sansMedium : sansRegular, size: size)
    }
    static func mono(_ size: Double, medium: Bool = false) -> Font {
        .custom(medium ? monoMedium : monoRegular, size: size)
    }

    // MARK: Spacing and radius

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32
    static let space12: CGFloat = 48

    /// Chips, inputs, small buttons.
    static let radiusSm: CGFloat = 4
    /// Buttons, menus, tooltips.
    static let radiusMd: CGFloat = 8
    /// Cards, panels, dialogs.
    static let radiusLg: CGFloat = 12

    // MARK: Frame info presets

    /// Swatches for the frame info font and background colours (§6).
    static let frameInfoPresets: [(name: String, rgba: RGBA)] = [
        ("Crust", RGBA(hex: 0x11111B)), ("Base", RGBA(hex: 0x1E1E2E)),
        ("Surface", RGBA(hex: 0x313244)), ("Overlay", RGBA(hex: 0x6C7086)),
        ("Text", RGBA(hex: 0xCDD6F4)), ("White", RGBA(hex: 0xFFFFFF)),
        ("Mauve", RGBA(hex: 0xCBA6F7)), ("Red", RGBA(hex: 0xF38BA8)),
        ("Peach", RGBA(hex: 0xFAB387)), ("Yellow", RGBA(hex: 0xF9E2AF)),
        ("Green", RGBA(hex: 0xA6E3A1)), ("Teal", RGBA(hex: 0x94E2D5)),
        ("Blue", RGBA(hex: 0x89B4FA)), ("Lavender", RGBA(hex: 0xB4BEFE)),
    ]
}

/// Catppuccin Mocha.
enum Palette {
    static let rosewater = Color(hex: 0xF5E0DC)
    static let flamingo = Color(hex: 0xF2CDCD)
    static let pink = Color(hex: 0xF5C2E7)
    static let mauve = Color(hex: 0xCBA6F7)
    static let red = Color(hex: 0xF38BA8)
    static let maroon = Color(hex: 0xEBA0AC)
    static let peach = Color(hex: 0xFAB387)
    static let yellow = Color(hex: 0xF9E2AF)
    static let green = Color(hex: 0xA6E3A1)
    static let teal = Color(hex: 0x94E2D5)
    static let sky = Color(hex: 0x89DCEB)
    static let sapphire = Color(hex: 0x74C7EC)
    static let blue = Color(hex: 0x89B4FA)
    static let lavender = Color(hex: 0xB4BEFE)
    static let text = Color(hex: 0xCDD6F4)
    static let subtext1 = Color(hex: 0xBAC2DE)
    static let subtext0 = Color(hex: 0xA6ADC8)
    static let overlay2 = Color(hex: 0x9399B2)
    static let overlay1 = Color(hex: 0x7F849C)
    static let overlay0 = Color(hex: 0x6C7086)
    static let surface2 = Color(hex: 0x585B70)
    static let surface1 = Color(hex: 0x45475A)
    static let surface0 = Color(hex: 0x313244)
    static let base = Color(hex: 0x1E1E2E)
    static let mantle = Color(hex: 0x181825)
    static let crust = Color(hex: 0x11111B)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension RGBA {
    /// sRGB components of a SwiftUI colour (from the colour picker).
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent))
    }
}

/// A card in a sidebar: mantle with a 1 pt border.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(Theme.text)
            content
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mantle, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(Theme.border, lineWidth: 1))
    }
}
