import SwiftUI
import MuesliCore

enum MuesliTheme {
    // MARK: - Colors — Backgrounds (layered)

    static let backgroundDeep   = Color.adaptive(dark: 0x101114, light: 0xF7F8FA)
    static let backgroundBase   = Color.adaptive(dark: 0x15161A, light: 0xF8F9FB)
    static let backgroundRaised = Color.adaptive(dark: 0x1D1F24, light: 0xFFFFFF)
    static let backgroundHover  = Color.adaptive(dark: 0x262932, light: 0xF1F3F6)

    // MARK: - Surfaces (interactive elements)

    static let surfacePrimary   = Color.adaptive(dark: 0x292C34, light: 0xF3F5F7)
    static let surfaceSelected  = Color.adaptive(dark: 0x2A3140, light: 0xFFF3EA)
    static let surfaceBorder    = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.07,
        light: .black, lightAlpha: 0.08
    )

    // MARK: - Text hierarchy

    static let textPrimary = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.92,
        light: .black, lightAlpha: 0.88
    )
    static let textSecondary = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.62,
        light: .black, lightAlpha: 0.55
    )
    static let textTertiary = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.40,
        light: .black, lightAlpha: 0.33
    )

    // MARK: - Accent

    static let defaultAccentDarkHex = 0x6BA3F7
    static let defaultAccentLightHex = 0xF97316
    static let defaultAccent    = Color.adaptive(dark: defaultAccentDarkHex, light: defaultAccentLightHex)
    static var accentOverrideHex: String?
    static var accent: Color {
        if let hex = accentOverrideHex, !hex.isEmpty,
           let val = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) {
            return Color(hex: Int(val))
        }
        return defaultAccent
    }
    static var accentSubtle: Color { accent.opacity(0.15) }

    // MARK: - Semantic

    static let recording        = Color(hex: 0xEF4444)
    static let transcribing     = Color(hex: 0xF59E0B)
    static let success          = Color(hex: 0x34D399)

    // MARK: - Typography (SF Pro via .system())

    static func title1() -> Font { .system(size: 28, weight: .bold) }
    static func title2() -> Font { .system(size: 22, weight: .semibold) }
    static func title3() -> Font { .system(size: 18, weight: .semibold) }
    static func headline() -> Font { .system(size: 15, weight: .semibold) }
    static func body() -> Font { .system(size: 14, weight: .regular) }
    static func callout() -> Font { .system(size: 13, weight: .regular) }
    static func caption() -> Font { .system(size: 12, weight: .regular) }
    static func captionMedium() -> Font { .system(size: 12, weight: .medium) }

    // MARK: - Spacing (4pt grid)

    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing28: CGFloat = 28
    static let spacing32: CGFloat = 32
    static let spacing40: CGFloat = 40

    // MARK: - Layout

    static let pageMaxWidth: CGFloat = 1080
    static let pageHorizontalPadding: CGFloat = 42
    static let pageVerticalPadding: CGFloat = 36
    static let sectionSpacing: CGFloat = 24
    static let cardPadding: CGFloat = 20
    static let rowMinHeight: CGFloat = 44
    static let sidebarMinWidth: CGFloat = 244
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 288
    static let sidebarRowHeight: CGFloat = 40
    static let sidebarChildRowHeight: CGFloat = 32

    // MARK: - Corner radii

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 8
    static let cornerLarge: CGFloat = 12
    static let cornerXL: CGFloat = 16
}

extension View {
    func muesliPageContent(maxWidth: CGFloat = MuesliTheme.pageMaxWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, MuesliTheme.pageHorizontalPadding)
            .padding(.vertical, MuesliTheme.pageVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Color Helpers

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    static func adaptive(dark: Int, light: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }

    static func adaptiveAlpha(dark: NSColor, darkAlpha: CGFloat, light: NSColor, lightAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark.withAlphaComponent(darkAlpha)
                : light.withAlphaComponent(lightAlpha)
        })
    }
}
