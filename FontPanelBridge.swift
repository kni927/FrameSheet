import AppKit

// MARK: - Font Panel Bridge

class FontPanelBridge: NSObject {
    static let shared = FontPanelBridge()
    var onFontChange: ((String) -> Void)?

    func showFontPanel(currentFontName: String, onFontChange: @escaping (String) -> Void) {
        self.onFontChange = onFontChange

        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.action = #selector(changeFont(_:))

        let fontPanel = fontManager.fontPanel(true)
        fontPanel?.makeKeyAndOrderFront(nil)

        if let currentFont = NSFont(name: currentFontName, size: 12.0) {
            fontManager.setSelectedFont(currentFont, isMultiple: false)
        }
    }

    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }
        let dummyFont = NSFont.systemFont(ofSize: 12)
        let selectedFont = fontManager.convert(dummyFont)
        let fontName = selectedFont.fontName
        onFontChange?(fontName)
    }
}
