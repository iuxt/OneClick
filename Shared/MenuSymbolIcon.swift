import AppKit

/// Finder draws these symbols in its own process. Use explicit palette colors
/// and cache each appearance separately.
nonisolated enum MenuSymbolIcon {
    enum Style: Hashable {
        case finderMenu
        case standard(pointSize: CGFloat)

        var configuration: NSImage.SymbolConfiguration {
            switch self {
            case .finderMenu:
                NSImage.SymbolConfiguration(pointSize: 13, weight: .light, scale: .small)
            case .standard(let pointSize):
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            }
        }
    }

    private struct Key: Hashable {
        let name: String
        let style: Style
        let isDark: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: NSImage] = [:]

    static func image(named name: String, style: Style = .finderMenu) -> NSImage? {
        let isDark = (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
        return image(named: name, style: style, isDark: isDark)
    }

    static func image(named name: String, style: Style = .finderMenu, isDark: Bool) -> NSImage? {
        let key = Key(name: name, style: style, isDark: isDark)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let palette = NSImage.SymbolConfiguration(paletteColors: [isDark ? .white : .black])
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(style.configuration.applying(palette)) else { return nil }
        cache[key] = image
        return image
    }
}
