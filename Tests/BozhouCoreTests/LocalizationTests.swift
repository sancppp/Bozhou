import Foundation
@testable import BozhouCore

extension CoreTests {
    func testLocalizationAndLanguageMigration() throws {
        defer { L10n.configure(.english) }
        XCTAssertEqual(L10n.language, .english)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).language, .english)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"language":"future"}"#.utf8)).language, .english)
        let store = try Store(url: root.appendingPathComponent("language.sqlite"))
        var settings = AppSettings(); settings.language = .simplifiedChinese
        try store.saveSettings(settings)
        XCTAssertEqual(try Store(url: root.appendingPathComponent("language.sqlite")).loadSettings().language, .simplifiedChinese)

        let argument = #"生产 %@ %d {1} \ " 😀"#
        for language in AppLanguage.allCases {
            L10n.configure(language)
            XCTAssertEqual(Authentication.password.title, language == .english ? "Password" : "密码")
            XCTAssertEqual(BozhouError.cancelled.localizedDescription, language == .english ? "Operation cancelled" : "操作已取消")
            XCTAssertEqual(L10n.tr("Close \(argument)"), (language == .english ? "Close " : "关闭 ") + argument)
            XCTAssertEqual(L10n.tr("SFTP: \(argument)\n\(123)"), (language == .english ? "SFTP: " : "SFTP：") + argument + "\n123")
            XCTAssertEqual(L10n.tr("Missing key \(argument)"), "Missing key " + argument)
            let host = Host(name: argument, address: "localhost", group: argument)
            let launch = try ConnectionBuilder(paths: AppPaths(root: root), askPass: "/usr/bin/false")
                .build(host: host, hosts: [host], identities: [])
            XCTAssertEqual(launch.environment["BOZHOU_LANGUAGE"], language.rawValue)
            // Locale changes must not alter protocols, user data or remote shell configuration.
            XCTAssertEqual(host.name, argument)
            XCTAssertTrue(host.folderPath.hasSuffix(argument))
            launch.cleanup()
        }
        let pattern = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func placeholders(_ text: String) -> [String] {
            let ns = text as NSString
            return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        var catalogs: [[String: String]] = []
        for language in AppLanguage.allCases {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Localizable", withExtension: "strings",
                                                     subdirectory: nil, localization: language.rawValue.lowercased()))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            XCTAssertTrue(table.count > 400)
            for (key, value) in table {
                XCTAssertEqual(placeholders(key), placeholders(value))
                XCTAssertTrue(!value.isEmpty)
                if language == .english { XCTAssertEqual(key, value) }
            }
            catalogs.append(table)
        }
        XCTAssertEqual(Set(catalogs[0].keys), Set(catalogs[1].keys))
    }
}
