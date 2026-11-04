import Foundation
import BozhouCore

extension CoreTests {
    func testHostKeyRecoveryScopeAndStaleWarning() throws {
        let paths = try AppPaths(root: root)
        let builder = ConnectionBuilder(paths: paths, askPass: "/usr/bin/false")
        let gateway = Host(name: "gateway", address: "gateway.example")
        var target = Host(name: "target", address: "192.0.2.2", port: 2222)
        target.jumpHosts = [gateway.id]
        let launch = try builder.build(host: target, hosts: [gateway], identities: [])
        defer { launch.cleanup() }
        let endpoint = launch.hostKeyEndpoints[1]
        let original = "# retained\n\(endpoint.identifier),other.example ssh-ed25519 Zml4dHVyZQ==\ngateway.example ssh-ed25519 Zml4dHVyZQ==\n"
        try Data(original.utf8).write(to: paths.knownHosts)
        func warning(_ identifier: String) -> String {
            """
            @ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
            SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.
            Offending ED25519 key in /untrusted/path:999
            Host key for \(identifier) has changed and you have requested strict checking.
            Host key verification failed.
            kex_exchange_identification: Connection closed by remote host
            Connection closed by UNKNOWN port 65535
            """
        }
        let failure = try XCTUnwrap(SSHHostKeyFailure.detect(output: warning(endpoint.identifier), launch: launch))
        XCTAssertEqual(failure.endpoint.hostID, target.id)
        XCTAssertEqual(failure.fingerprint, "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        // Detection/cancelling has no effect on trust. Nor can an unrelated warning
        // select a local entry, even when its path and line number look plausible.
        XCTAssertEqual(try Data(contentsOf: paths.knownHosts), Data(original.utf8))
        XCTAssertNil(SSHHostKeyFailure.detect(output: warning("other.example"), launch: launch))
        XCTAssertNil(SSHHostKeyFailure.detect(output: "Host key verification failed", launch: launch))
        try failure.resetTrust()
        XCTAssertEqual(try String(contentsOf: paths.knownHosts),
                       "# retained\nother.example ssh-ed25519 Zml4dHVyZQ==\ngateway.example ssh-ed25519 Zml4dHVyZQ==\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: paths.knownHosts.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try failure.resetTrust())

        // Real OpenSSH-hashed identifiers (including IPv6/non-default ports).
        target.jumpHosts = []; target.address = "2001:db8::1"
        let direct = try builder.build(host: target, hosts: [], identities: [])
        defer { direct.cleanup() }
        let identifier = direct.hostKeyEndpoints[0].identifier
        XCTAssertEqual(identifier, "[2001:db8::1]:2222")
        try Data("\(identifier) ssh-ed25519 Zml4dHVyZQ==\nother.example ssh-ed25519 Zml4dHVyZQ==\n".utf8).write(to: paths.knownHosts)
        let hash = Process()
        hash.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        hash.arguments = ["-H", "-f", paths.knownHosts.path]
        hash.standardOutput = FileHandle.nullDevice; hash.standardError = FileHandle.nullDevice
        try hash.run(); hash.waitUntilExit(); XCTAssertEqual(hash.terminationStatus, 0)
        let hashed = try String(contentsOf: paths.knownHosts)
        let changed = try XCTUnwrap(SSHHostKeyFailure.detect(output: warning(identifier), launch: direct))
        try Data((hashed + "# learned by another connection\n").utf8).write(to: paths.knownHosts)
        let latest = try Data(contentsOf: paths.knownHosts)
        XCTAssertThrowsError(try changed.resetTrust())
        XCTAssertEqual(try Data(contentsOf: paths.knownHosts), latest)
        let current = try XCTUnwrap(SSHHostKeyFailure.detect(output: warning(identifier), launch: direct))
        try current.resetTrust()
        XCTAssertEqual(try String(contentsOf: paths.knownHosts), hashed.components(separatedBy: "\n").dropFirst().joined(separator: "\n") + "# learned by another connection\n")
    }
}
