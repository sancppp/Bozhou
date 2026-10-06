import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// Interpolations are arguments, never part of the lookup key or a printf format.
/// Translators may reorder {0}, {1}, … without interpreting user-provided text.
public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    private static let lock = NSLock()
    private static var selected: AppLanguage = .english
    private static let bundles: [AppLanguage: Bundle] = {
        // A distributed app must not rely on SwiftPM's absolute build-directory fallback.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Bozhou_BozhouCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
            // SwiftPM lowercases localization directory names.
            guard let path = resources.path(forResource: language.rawValue.lowercased(), ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        })
    }()
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    public static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }; return selected
    }

    /// Configure once at process startup. Preferences take effect on the next launch.
    public static func configure(_ language: AppLanguage) {
        lock.lock(); selected = language; lock.unlock()
    }

    /// Configure system-owned menus and panels before creating NSApplication.
    /// The volatile argument domain is process-local and overrides the system preference.
    public static func configureSystemUI() {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["AppleLanguages"] = [language.rawValue, "en"]
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    public static func date(_ value: Date, abbreviated: Bool = false) -> String {
        value.formatted(Date.FormatStyle(date: abbreviated ? .abbreviated : .numeric, time: .shortened)
            .locale(language.locale))
    }

    public static func tr(_ text: LocalizedText) -> String {
        let translated = bundles[language]?.localizedString(forKey: text.key, value: text.key, table: nil) ?? text.key
        let template = translated as NSString
        var output = "", offset = 0
        // Single pass: placeholders inside substituted filenames, commands or errors stay literal.
        for match in placeholder.matches(in: translated, range: NSRange(location: 0, length: template.length)) {
            output += template.substring(with: NSRange(location: offset, length: match.range.location - offset))
            if let index = Int(template.substring(with: match.range(at: 1))), text.arguments.indices.contains(index) {
                output += text.arguments[index]
            } else { output += template.substring(with: match.range) }
            offset = NSMaxRange(match.range)
        }
        output += template.substring(from: offset)
        return output
    }
}
