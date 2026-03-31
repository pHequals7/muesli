import AppKit

enum MenuBarIconRenderer {

    /// Returns a template `mic.fill` SF Symbol sized for the macOS menu bar.
    /// Template mode means AppKit handles dark/light/tinted menu bar adaptation automatically.
    static func make() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Muesli")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }
}
