import AppKit
import BozhouCore

enum TerminalAppearance {
    static var fonts: [String] {
        NSFontManager.shared.availableFonts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func font(_ settings: AppSettings) -> NSFont {
        NSFont(name: settings.fontName, size: settings.fontSize)
            ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    }

    static func color(hex: String?) -> NSColor? {
        guard let hex else { return nil }
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), let rgb = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func background(hex: String?, dark: Bool) -> NSColor {
        color(hex: hex) ?? color(hex: dark ? "#0E141F" : "#F1F2F4")!
    }

    /// Choose the foreground with the higher sRGB contrast, independently of the app theme.
    static func usesLightText(on background: NSColor) -> Bool {
        let rgb = background.usingColorSpace(.sRGB) ?? .white
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance < 0.179
    }

    static func foreground(on background: NSColor) -> NSColor {
        usesLightText(on: background) ? color(hex: "#F4F6F8")! : color(hex: "#111820")!
    }
}
