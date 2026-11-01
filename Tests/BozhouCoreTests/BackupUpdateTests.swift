import Foundation
import CryptoKit
@testable import BozhouCore

extension CoreTests {
    func testBackupRoundTripAndValidation() throws {
        let source = try AppPaths(root: root.appendingPathComponent("source"))
        let store = try Store(url: source.database)
        let key = Identity(name: "key", privateKeyPath: "/not-copied/private-key", publicKey: "fixture", fingerprint: "fixture", group: "Team/Keys")
        try store.save(key)
        try store.save(IdentityFolder(path: "Team/Keys"))
        let jump = Host(name: "jump", address: "localhost")
        var host = Host(name: "中文主机", address: "localhost", group: "Team/Hosts")
        host.password = "fixture-password"; host.jumpHosts = [jump.id]; host.identityID = key.id
        try store.save(jump); try store.save(host); try store.save(HostFolder(path: host.group))
        let item = Interaction(hostName: host.name, sessionID: UUID(), shell: "zsh", command: "printf 中文", output: "输出\n")
        try store.save(item); try store.save(Pin(item)); try store.save(Snippet(name: "snippet", command: "true"))
        var settings = AppSettings(); settings.language = .simplifiedChinese; settings.tabPlacement = .vertical
        try store.saveSettings(settings)
        try Data("fixture-known-hosts".utf8).write(to: source.knownHosts)
        try Data("fixture-log".utf8).write(to: source.logs.appendingPathComponent("sample.ssh.log"))
        try Data("must not copy session config".utf8).write(to: source.sessions.appendingPathComponent("config"))
        let backup = try WorkspaceBackup.capture(store: store, paths: source)
        let file = root.appendingPathComponent("test.bozhoubackup")
        try backup.write(to: file)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let decoded = try WorkspaceBackup.read(from: file)
        let restored = try decoded.restore(to: root.appendingPathComponent("restored"))
        let next = try Store(url: restored.database)
        XCTAssertEqual(try next.list(Host.self), try store.list(Host.self))
        XCTAssertEqual(try next.list(Identity.self), try store.list(Identity.self))
        XCTAssertEqual(try next.list(IdentityFolder.self), try store.list(IdentityFolder.self))
        XCTAssertEqual(try next.list(HostFolder.self), try store.list(HostFolder.self))
        XCTAssertEqual(try next.list(Interaction.self), try store.list(Interaction.self))
        XCTAssertEqual(try next.list(Pin.self), try store.list(Pin.self))
        XCTAssertEqual(try next.list(Snippet.self), try store.list(Snippet.self))
        XCTAssertEqual(try next.loadSettings(), settings)
        XCTAssertEqual(try Data(contentsOf: restored.knownHosts), try Data(contentsOf: source.knownHosts))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: restored.sessions.path), [])
        XCTAssertEqual(try String(contentsOf: restored.logs.appendingPathComponent("sample.ssh.log")), "fixture-log")
        XCTAssertThrowsError(try decoded.restore(to: source.root))
        var invalid = decoded
        invalid.logs = [.init(name: "../outside", data: Data())]
        XCTAssertThrowsError(try invalid.restore(to: root.appendingPathComponent("unsafe")))
        invalid = decoded; invalid.hosts.append(host)
        XCTAssertThrowsError(try invalid.write(to: file))
        var envelope = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]
        envelope["sha256"] = String(repeating: "0", count: 64)
        try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0).write(to: file)
        XCTAssertThrowsError(try WorkspaceBackup.read(from: file))
        XCTAssertEqual(try store.list(Host.self).count, 2)
    }
    func testReleaseVersionsAssetsAndChecksums() throws {
        XCTAssertTrue(ReleaseVersion("release/v1.10.0")! > ReleaseVersion("v1.9.9")!)
        XCTAssertNil(ReleaseVersion("1.2.3-beta"))
        XCTAssertNil(ReleaseVersion("1.2"))
        XCTAssertNil(ReleaseVersion("1.2.-3"))
        let filename = "Bozhou-1.2.0-macOS-arm64.zip"
        func release(_ version: String = "release/v1.2.0", prerelease: Bool = false, assets: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "tag_name": version, "draft": false, "prerelease": prerelease, "body": "Notes",
                "html_url": "https://github.com/sancppp/Bozhou/releases/tag/release/v1.2.0",
                "assets": assets ? [
                    ["name": filename, "browser_download_url": "https://github.com/sancppp/Bozhou/releases/download/release/v1.2.0/\(filename)", "size": 10],
                    ["name": "SHA256SUMS", "browser_download_url": "https://github.com/sancppp/Bozhou/releases/download/release/v1.2.0/SHA256SUMS", "size": 200]
                ] : []
            ])
        }
        XCTAssertEqual(try ReleaseUpdate.parse(release(), current: ReleaseVersion("1.1.1")!)?.filename, filename)
        XCTAssertNil(try ReleaseUpdate.parse(release(), current: ReleaseVersion("1.2.0")!))
        XCTAssertNil(try ReleaseUpdate.parse(release(prerelease: true), current: ReleaseVersion("1.1.1")!))
        XCTAssertThrowsError(try ReleaseUpdate.parse(release(assets: false), current: ReleaseVersion("1.1.1")!))
        let data = Data("test data".utf8), file = root.appendingPathComponent(filename)
        try data.write(to: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ReleaseUpdate.checksum("\(hash)  \(filename)\n", filename: filename), hash)
        XCTAssertThrowsError(try ReleaseUpdate.checksum("\(hash) other.zip", filename: filename))
        XCTAssertThrowsError(try ReleaseUpdate.checksum("\(hash)  \(filename)\n\(hash)  \(filename)", filename: filename))
        try ReleaseUpdate.verify(file: file, sha256: hash)
        XCTAssertThrowsError(try ReleaseUpdate.verify(file: file, sha256: String(repeating: "0", count: 64)))
    }
    func testUpdateArchiveAndRollback() throws {
        let fm = FileManager.default
        let app = root.appendingPathComponent("泊舟.app"), macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data("binary fixture".utf8).write(to: macos.appendingPathComponent("Bozhou"))
        try Data("plist fixture".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let zip = root.appendingPathComponent("update.zip")
        try UpdateArchive.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
        try UpdateArchive.validate(zip)
        let extracted = try UpdateArchive.extract(zip, into: root.appendingPathComponent("expanded"))
        XCTAssertThrowsError(try UpdateArchive.extract(zip, into: root.appendingPathComponent("expanded")))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Contents/MacOS/Bozhou")), Data("binary fixture".utf8))
        XCTAssertThrowsError(try UpdateArchive.verifyApp(extracted))
        for path in ["../escape", "泊舟.app/../../escape", "泊舟.app//Contents/x", "泊舟.app/./x", "泊舟.app/a\\b", "/泊舟.app/x"] {
            XCTAssertTrue(!UpdateArchive.safeName(path))
        }
        try fm.createSymbolicLink(at: macos.appendingPathComponent("escape"), withDestinationURL: root)
        let badZip = root.appendingPathComponent("symlink.zip")
        try UpdateArchive.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, badZip.path])
        XCTAssertThrowsError(try UpdateArchive.validate(badZip))
        let staged = root.appendingPathComponent("new.app"), installed = root.appendingPathComponent("old.app")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
        XCTAssertThrowsError(try AppReplacement.commit(staged: staged, target: installed, validate: { _ in }, launch: { _ in throw BozhouError.cancelled }))
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker")), "old")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
        let previous = try AppReplacement.commit(staged: staged, target: installed, validate: { _ in }, launch: { _ in })
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker")), "new")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("marker")), "old")
    }
}
