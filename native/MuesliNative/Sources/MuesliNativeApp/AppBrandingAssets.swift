import AppKit
import Foundation

enum AppBrandingAssets {
    private static let directoryName = "Branding"
    private static let logoFileName = "custom-logo.png"

    static func importLogo(from sourceURL: URL, supportDirectory: URL = AppIdentity.supportDirectoryURL) throws -> String {
        guard let image = NSImage(contentsOf: sourceURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(logoFileName)
        try pngData.write(to: destination, options: .atomic)
        return destination.path
    }

    static func removeLogo(at path: String?) {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    static func image(at path: String?) -> NSImage? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }

    static func accentedDefaultAppIcon(accentHex: String, fallbackURL: URL?) -> NSImage? {
        let accent = NSColor.appBrandingColor(hex: accentHex)
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        let bounds = NSRect(origin: .zero, size: size)
        let iconRect = bounds.insetBy(dx: 108, dy: 108)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        bounds.fill()

        let backgroundPath = NSBezierPath(roundedRect: iconRect, xRadius: 232, yRadius: 232)
        NSGradient(
            starting: accent.appBrandingHighlight,
            ending: accent.appBrandingShadow
        )?.draw(in: backgroundPath, angle: -45)

        NSColor.white.withAlphaComponent(0.18).setStroke()
        backgroundPath.lineWidth = 8
        backgroundPath.stroke()

        if let url = Bundle.main.url(forResource: "menu_m_template", withExtension: "png"),
           let mark = NSImage(contentsOf: url) {
            let markRect = bounds.insetBy(dx: 298, dy: 318)
            mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill()
            markRect.fill(using: .sourceAtop)
        } else if let fallbackURL,
                  let fallback = NSImage(contentsOf: fallbackURL) {
            fallback.draw(in: iconRect.insetBy(dx: 140, dy: 140), from: .zero, operation: .sourceOver, fraction: 1)
        }

        image.isTemplate = false
        return image
    }
}

private extension NSColor {
    static func appBrandingColor(hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            return NSColor(red: 0.98, green: 0.38, blue: 0.0, alpha: 1.0)
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var appBrandingHighlight: NSColor {
        blended(withFraction: 0.20, of: .white) ?? self
    }

    var appBrandingShadow: NSColor {
        blended(withFraction: 0.16, of: .black) ?? self
    }
}
