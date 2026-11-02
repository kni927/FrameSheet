import SwiftUI

// Catppuccin Mocha (MIT, docs/licenses/Catppuccin-LICENSE), the base of the
// kni Design System. The design system's type and spacing tokens come in a
// later TASK; until then views use system fonts and these colours only.
enum Theme {
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

    /// Accent for selection and focus.
    static let accent = mauve
    static let windowBackground = base
    static let sidebarBackground = mantle
    static let printBackground = crust
    static let thumbPlaceholder = surface0
    static let primaryText = text
    static let secondaryText = subtext0
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
