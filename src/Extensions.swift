import SwiftUI
import AppKit

// MARK: - Color Conversion Extension

extension Color {
    func toHex() -> String {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else {
            return "000000"
        }
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Font Modifiers

struct MonoFontModifier: ViewModifier {
    var size: CGFloat = 11
    var weight: Font.Weight = .regular

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    func monoFont(size: CGFloat = 11, weight: Font.Weight = .regular) -> some View {
        self.modifier(MonoFontModifier(size: size, weight: weight))
    }
}

// MARK: - NSImage Extension

extension NSImage {
    var pixelSize: NSSize {
        if let representation = representations.first {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }

    var aspectRatio: CGFloat {
        let pSize = pixelSize
        guard pSize.width > 0 else { return 1.0 }
        return pSize.height / pSize.width
    }
}
