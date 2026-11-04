import Foundation
import Darwin
import BozhouCore

enum HostKeyRotationIntegrationTests {
    static func run(root: URL, fixture: [String: Any], identity: Identity, askpass: String) async throws {
        let paths = try AppPaths(root: root.appendingPathComponent("reinstalled-hosts"))
        let accepting = ConnectionBuilder(paths: paths, askPass: askpass)
        let rejecting = ConnectionBuilder(paths: paths, askPass: "/usr/bin/false")
        let sites = fixture["routes"] as! [[String: Any]]
        func host(_ name: String, _ address: String, _ port: Int = 22) -> BozhouCore.Host {
            var value = Host(name: name, address: address, port: port, username: "tester", authentication: .identity)
            value.identityID = identity.id
            return value
        }
        var routes: [[BozhouCore.Host]] = []
        for site in sites {
            let gateway = host("gateway-\(site["site"]!)", "127.0.0.1", site["gateway_port"] as! Int)
            var relay = host("relay", "192.0.2.1"); relay.jumpHosts = [gateway.id]
            var target = host("target", "192.0.2.2"); target.jumpHosts = [relay.id]
            routes.append([gateway, relay, target])
        }
        let direct = host("direct", "127.0.0.1", (fixture["ports"] as! [Int])[2])
        func launch(_ route: [BozhouCore.Host], _ builder: ConnectionBuilder) throws -> SSHLaunch {
            try builder.build(host: route.last!, hosts: route, identities: [identity], sftp: true)
        }
        func command(_ route: [BozhouCore.Host], _ builder: ConnectionBuilder) throws -> (Int32, String, SSHLaunch) {
            let ssh = try launch(route, builder)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: ssh.executable)
            process.arguments = ["-E", ssh.logURL!.path, "-F", ssh.directory.appendingPathComponent("config").path,
                                 "-T", "bz-\(route.count - 1)", "printf key-rotation-ok"]
            process.environment = ssh.environment; process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let diagnostic = TerminalDiagnostic.tail(of: ssh.logURL)
            ssh.cleanup()
            return (process.terminationStatus, text + "\n" + diagnostic, ssh)
        }
        for route in routes + [[direct]] { XCTAssertEqual(try command(route, accepting).0, 0) }
        let other = SFTPClient(launch: try launch(routes[1], rejecting))
        defer { other.cancel() }
        _ = try await other.connect()
        for (number, index) in [2, 1, 0, 0].enumerated() {
            let route = number == 3 ? [direct] : routes[0]
            let old = try Data(contentsOf: paths.knownHosts)
            XCTAssertEqual(kill(pid_t(fixture["pid"] as! Int), SIGUSR2), 0)
            let deadline = Date().addingTimeInterval(5)
            var rotation: [String: Any] = [:]
            while Date() < deadline {
                if let data = try? Data(contentsOf: root.appendingPathComponent("rotation.json")),
                   let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   result["number"] as? Int == number + 1 {
                    rotation = result; break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(rotation["number"] as? Int, number + 1)
            let failed = try command(route, accepting)
            XCTAssertEqual(failed.0, 255)
            let change = try XCTUnwrap(SSHHostKeyFailure.detect(output: failed.1, launch: failed.2))
            XCTAssertEqual(change.endpoint.hostID, route[index].id)
            XCTAssertEqual(change.fingerprint, rotation["fingerprint"] as? String ?? "")
            XCTAssertEqual(try Data(contentsOf: paths.knownHosts), old)
            // The typed SFTP failure must include the actual failed hop even when
            // outer SSH only reports kex_exchange_identification / UNKNOWN 65535.
            let sftp = SFTPClient(launch: try launch(route, accepting))
            do { _ = try await sftp.connect(); fail("SFTP accepted a changed key") }
            catch {
                let sftpFailure = try XCTUnwrap(error as? SSHHostKeyFailure)
                XCTAssertEqual(sftpFailure.endpoint, change.endpoint)
                XCTAssertEqual(sftpFailure.fingerprint, change.fingerprint)
            }
            sftp.cancel()
            XCTAssertEqual(try Data(contentsOf: paths.knownHosts), old)
            try change.resetTrust()
            let reset = try Data(contentsOf: paths.knownHosts)
            XCTAssertTrue(reset != old)
            // Reset alone must not accept the replacement: its confirmation can
            // still be refused, leaving the other site's keys usable.
            XCTAssertEqual(try command(route, rejecting).0, 255)
            XCTAssertEqual(try Data(contentsOf: paths.knownHosts), reset)
            XCTAssertEqual(try command(routes[1], rejecting).0, 0)
            _ = try await other.list("/")
            XCTAssertEqual(try command(route, accepting).0, 0)
            XCTAssertEqual(try command(route, rejecting).0, 0)
            let restored = SFTPClient(launch: try launch(route, rejecting))
            _ = try await restored.connect(); _ = try await restored.list("/"); restored.cancel()
            print("PASS real \(rotation["role"] ?? "") key rotation: SSH/SFTP identify the hop, preserve trust on cancel, scoped reset, require confirmation and reconnect")
        }
    }
}
