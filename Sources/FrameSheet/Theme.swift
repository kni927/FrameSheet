import AppKit
import FrameSheetCore
import SwiftUI

// The kni Design System, Mocha (dark) theme: colour, type, spacing and radius
// tokens. Colours are Catppuccin Mocha (MIT, docs/licenses/Catppuccin-LICENSE);
// fonts are the system's. Views use the token names, not the palette.
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

    // System fonts: SF Pro, SF Mono and SF Pro Condensed (owner, 2026-11-03).
    // The system cascade list renders Japanese text (file names) in Hiragino
    // Sans.

    /// Labels and metadata, 12/500, in textMuted.
    static let caption = Font.system(size: 12, weight: .medium)
    /// Dense lists and controls, 13/400.
    static let bodySm = Font.system(size: 13)
    static let body = Font.system(size: 15)
    static let heading2 = Font.system(size: 19, weight: .semibold)
    static let heading1 = Font.system(size: 24, weight: .semibold)
    /// Code, paths and numbers that line up, 13/400.
    static let code = Font.system(size: 13, design: .monospaced)

    /// Section titles in the sidebars: caption size at the medium weight,
    /// in `text`.
    static let label = Font.system(size: 13, weight: .medium)
    /// Section titles in the right panel and the Settings window, 16/600
    /// in `text` (owner, 2026-11-03: larger and bolder than the rows).
    static let sectionTitle = Font.system(size: 16, weight: .semibold)
    /// Secondary text in the panels: caption size at the regular weight, so
    /// panel text stays lighter than its section titles.
    static let panelCaption = Font.system(size: 12)
    /// Large numbers of the grid stats.
    static let statValue = Font.system(size: 20, weight: .regular).monospacedDigit()
    static func sans(_ size: Double, medium: Bool = false) -> Font {
        .system(size: size, weight: medium ? .medium : .regular)
    }
    static func mono(_ size: Double, medium: Bool = false) -> Font {
        .system(size: size, weight: medium ? .medium : .regular, design: .monospaced)
    }
    static func condensed(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).width(.condensed)
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

    /// Swatches for the frame info font and background colours (§6); the
    /// colour picker and Transparent cover the rest.
    static let frameInfoPresets: [(name: String, rgba: RGBA)] = [
        ("Crust", RGBA(hex: 0x11111B)), ("Text", RGBA(hex: 0xCDD6F4)),
        ("Mauve", RGBA(hex: 0xCBA6F7)), ("Yellow", RGBA(hex: 0xF9E2AF)),
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

/// A section of a sidebar: its heading over the content, divided from the
/// section above by a 1 pt line. Content text is regular weight.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.text)
                .padding(.bottom, 2)
            content
                .font(Theme.bodySm)
                .fontWeight(.regular)
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// One settings row: the label on the left, the value or control
/// right-aligned.
struct PanelRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        HStack(spacing: Theme.space2) {
            Text(title)
                .font(Theme.bodySm)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: Theme.space2)
            value
        }
        .frame(minHeight: 22)
    }
}

/// Icon buttons in the window toolbar and the panels: no Liquid Glass
/// capsule (owner, 2026-11-03), a square-ish `radiusSm` background on hover
/// and press, and `surface` while `selected` (an on toggle).
struct ToolbarIconStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconBody(configuration: configuration, selected: selected)
    }
}

private struct ToolbarIconBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
            .foregroundStyle(isEnabled ? Theme.text : Theme.textMuted.opacity(0.5))
            .frame(minWidth: 28, minHeight: 24)
            .padding(.horizontal, 2)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            .onHover { hovering = $0 }
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Theme.surfaceHover }
        if hovering || selected { return Theme.surface }
        return .clear
    }
}
