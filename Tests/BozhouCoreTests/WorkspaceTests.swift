import Foundation
import BozhouCore

extension CoreTests {
    func testIdentityFoldersAndMigration() throws {
        let id = UUID()
        let legacy = Data("""
        {"id":"\(id)","name":"legacy","privateKeyPath":"/tmp/key","publicKey":"","fingerprint":"fixture"}
        """.utf8)
        var key = try JSONDecoder().decode(Identity.self, from: legacy)
        XCTAssertEqual(key.group, "")
        let store = try Store(url: root.appendingPathComponent("folders.sqlite"))
        key.group = " Production / East / SSH "
        try store.saveIdentity(key)
        XCTAssertEqual(try store.identityGroups(), ["Production", "Production/East", "Production/East/SSH"])
        XCTAssertEqual(try store.list(Identity.self).first?.group, "Production/East/SSH")
        var host = Host(name: "fixture", address: "127.0.0.1", authentication: .identity)
        host.identityID = id
        try store.save(host)
        try store.save(HostFolder(path: "Production"))
        var settings = AppSettings()
        settings.expandedHostGroups = ["Production"]
        settings.expandedIdentityGroups = ["Production", "Production/East"]
        settings.tabPlacement = .vertical
        try store.saveSettings(settings)
        try store.renameIdentityFolder("Production", to: "Team/Production")
        XCTAssertEqual(try store.list(Identity.self).first?.id, id)
        XCTAssertEqual(try store.list(Identity.self).first?.group, "Team/Production/East/SSH")
        XCTAssertEqual(try store.list(Host.self).first?.identityID, id)
        XCTAssertEqual(try store.list(HostFolder.self).map(\.path), ["Production"])
        XCTAssertEqual(try store.loadSettings().expandedHostGroups, ["Production"])
        XCTAssertEqual(try store.loadSettings().expandedIdentityGroups, ["Team/Production", "Team/Production/East"])
        XCTAssertEqual(try store.loadSettings().tabPlacement, .vertical)
        XCTAssertThrowsError(try store.renameIdentityFolder("Team", to: "Team/Production/East"))
        try store.createIdentityFolder("Other")
        XCTAssertThrowsError(try store.renameIdentityFolder("Team", to: "Other"))
        XCTAssertThrowsError(try store.deleteIdentityFolder("Team"))
        XCTAssertThrowsError(try store.deleteIdentityFolder(""))
        XCTAssertEqual(try store.list(Identity.self).first?.group, "Team/Production/East/SSH")
        var moved = try XCTUnwrap(store.list(Identity.self).first)
        moved.group = "Other"
        moved.name = "Renamed"
        try store.saveIdentity(moved)
        try store.deleteIdentityFolder("Team/Production/East/SSH")
        try store.deleteIdentityFolder("Team/Production/East")
        XCTAssertEqual(try store.loadSettings().expandedIdentityGroups, ["Team/Production"])
        let reloaded = try Store(url: root.appendingPathComponent("folders.sqlite"))
        XCTAssertEqual(try reloaded.list(Identity.self).first, moved)
        XCTAssertEqual(try reloaded.identityGroups(), ["Other", "Team", "Team/Production"])
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(oldSettings.tabPlacement, .horizontal)
        XCTAssertTrue(oldSettings.expandedIdentityGroups.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"tabPlacement":"future"}"#.utf8)).tabPlacement, .horizontal)
        let copy = root.appendingPathComponent("backup.sqlite")
        try store.backup(to: copy)
        XCTAssertEqual(try Store(url: copy).list(IdentityFolder.self), try store.list(IdentityFolder.self))
    }

    func testUnicodeSearchAndOutputMatching() throws {
        let text = "😀部署 CAFÉ cafe\u{301} café\nerror ERROR"
        let hits = TextSearch.ranges(in: text, query: "cafe")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map { (text as NSString).substring(with: $0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) },
                       ["cafe", "cafe", "cafe"])
        XCTAssertEqual(TextSearch.ranges(in: text, query: "😀"), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(TextSearch.ranges(in: text, query: ""), [])
        XCTAssertEqual(TextSearch.ranges(in: "aaaa", query: "aa"), [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        XCTAssertTrue(!TextSearch.contains("abc", query: ".*"))
        XCTAssertNil(TextSearch.excerpt(text, query: "missing"))
        let output = String(repeating: "safe output\n", count: 15000) + "needle 命中"
        let item = Interaction(hostName: "fixture", sessionID: UUID(), shell: "zsh", command: "cat result", output: output)
        let name = HostDisplayName(name: item.hostName, hostname: "machine-abcdef")
        XCTAssertTrue(TextSearch.matches(item, name: name, query: "NEEDLE"))
        XCTAssertTrue(TextSearch.matches(item, name: name, query: "abcdef"))
        XCTAssertTrue(TextSearch.matches(item, name: name, query: "ZSH"))
        XCTAssertTrue(!TextSearch.matches(item, name: name, query: "missing"))
        let excerpt = try XCTUnwrap(TextSearch.excerpt(output, query: "命中"))
        XCTAssertTrue(excerpt.contains("needle 命中") && excerpt.count < 100)
        XCTAssertTrue(TextSearch.ranges(in: output, query: "needle").first!.location > 100000)
    }
}
