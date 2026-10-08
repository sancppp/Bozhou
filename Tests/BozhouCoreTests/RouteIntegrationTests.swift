import Foundation
import BozhouCore

enum RouteIntegrationTests {
    static func run(root: URL, fixture: [String: Any], identity: Identity, askpass: String) async throws {
        let sites = fixture["routes"] as! [[String: Any]]
        let paths = try AppPaths(root: root.appendingPathComponent("overlapping-networks"))
        let accepting = ConnectionBuilder(paths: paths, askPass: askpass)
        let rejecting = ConnectionBuilder(paths: paths, askPass: "/usr/bin/false")
        var targets: [BozhouCore.Host] = [], routes: [[BozhouCore.Host]] = []
        var initialTrust = ""
        for site in sites {
            var gateway = Host(name: "gateway", address: "127.0.0.1", port: site["gateway_port"] as! Int,
                               username: "tester", authentication: .identity)
            gateway.identityID = identity.id
            var relay = Host(name: "relay", address: "192.0.2.1", username: "tester", authentication: .identity)
            relay.identityID = identity.id; relay.jumpHosts = [gateway.id]
            var target = Host(name: "target", address: "192.0.2.2", username: "tester", authentication: .identity)
            target.identityID = identity.id; target.jumpHosts = [relay.id]
            targets.append(target); routes.append([gateway, relay])
            initialTrust += "[127.0.0.1]:\(gateway.port) \(site["gateway_key"] as! String)\n"
        }
        try Data(initialTrust.utf8).write(to: paths.knownHosts)

        func launch(_ index: Int, builder: ConnectionBuilder) throws -> SSHLaunch {
            try builder.build(host: targets[index], hosts: routes[index], identities: [identity], sftp: true)
        }
        func command(_ index: Int, builder: ConnectionBuilder, legacy: Bool = false) throws -> (Int32, String) {
            let ssh = try launch(index, builder: builder)
            defer { ssh.cleanup() }
            let config = ssh.directory.appendingPathComponent("config")
            if legacy {
                // Reproduce the old address-only policy with real OpenSSH.
                let text = try String(contentsOf: config, encoding: .utf8)
                    .components(separatedBy: "\n").filter { !$0.hasPrefix("    HostKeyAlias ") }.joined(separator: "\n")
                try text.write(to: config, atomically: true, encoding: .utf8)
            }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: ssh.executable)
            process.arguments = ["-E", ssh.logURL!.path, "-F", config.path, "-T", "bz-2",
                                 "cat site-\(sites[index]["site"] as! String).txt"]
            process.environment = ssh.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text + (try String(contentsOf: ssh.logURL!, encoding: .utf8)))
        }
        XCTAssertEqual(try command(0, builder: accepting, legacy: true).0, 0)
        let collision = try command(1, builder: accepting, legacy: true)
        XCTAssertTrue(collision.0 != 0 && collision.1.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        let legacyTrust = try Data(contentsOf: paths.knownHosts)
        print("PASS 复现旧行为：不同跳板后的同 IP/端口，先登录 A 后 B 出现指纹冲突")

        // Existing address-only keys cannot establish which routed host was trusted.
        // Refusing the new confirmation must fail without silently inheriting them.
        XCTAssertTrue(try command(0, builder: rejecting).0 != 0)
        XCTAssertEqual(try Data(contentsOf: paths.knownHosts), legacyTrust)
        let clientA = SFTPClient(launch: try launch(0, builder: accepting))
        let clientB = SFTPClient(launch: try launch(1, builder: accepting))
        defer { clientA.cancel(); clientB.cancel() }
        async let homeA = clientA.connect()
        async let homeB = clientB.connect()
        let homes = try await (homeA, homeB)
        XCTAssertEqual(homes.0, "/"); XCTAssertEqual(homes.1, "/")
        let filesA = try await clientA.list("/")
        let filesB = try await clientB.list("/")
        XCTAssertTrue(filesA.contains { $0.name == "site-a.txt" } && !filesA.contains { $0.name == "site-b.txt" })
        XCTAssertTrue(filesB.contains { $0.name == "site-b.txt" } && !filesB.contains { $0.name == "site-a.txt" })
        print("PASS 旧指纹保留、首次仍需确认；两套同 IP/端口及同中间跳板地址的 SFTP 并发连接且目录互不混淆")

        // Hold both SSH sessions open at once, alongside the two live SFTP clients.
        var sessions: [(Process, Pipe, Pipe, SSHLaunch)] = []
        defer {
            for (process, input, _, ssh) in sessions {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                ssh.cleanup()
            }
        }
        for index in targets.indices {
            let ssh = try launch(index, builder: rejecting)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: ssh.executable)
            process.arguments = ["-F", ssh.directory.appendingPathComponent("config").path, "-T", "bz-2",
                                 "cat site-\(sites[index]["site"] as! String).txt; cat"]
            process.environment = ssh.environment
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            sessions.append((process, input, output, ssh))
            try process.run()
        }
        for (index, session) in sessions.enumerated() {
            let ready = session.2.fileHandleForReading.readData(ofLength: 7)
            XCTAssertEqual(String(decoding: ready, as: UTF8.self), "site-\(sites[index]["site"] as! String)\n")
            XCTAssertTrue(session.0.isRunning)
        }
        for (index, session) in sessions.enumerated() {
            let marker = Data("session-\(index)\n".utf8)
            try session.1.fileHandleForWriting.write(contentsOf: marker)
            try session.1.fileHandleForWriting.close()
            XCTAssertEqual(session.2.fileHandleForReading.readDataToEndOfFile(), marker)
            session.0.waitUntilExit()
            XCTAssertEqual(session.0.terminationStatus, 0)
        }
        let trusted = try Data(contentsOf: paths.knownHosts)
        XCTAssertTrue(trusted.starts(with: legacyTrust))
        for index in targets.indices {
            XCTAssertEqual(try command(index, builder: rejecting).0, 0)
            let reconnected = SFTPClient(launch: try launch(index, builder: rejecting))
            _ = try await reconnected.connect()
            _ = try await reconnected.list("/")
            reconnected.cancel()
        }
        XCTAssertEqual(try Data(contentsOf: paths.knownHosts), trusted)
        print("PASS 两个 SSH 会话同时保持连接、独立收发；SSH/SFTP 重连复用指纹，无需再次确认")

        let config = try String(contentsOf: sessions[0].3.directory.appendingPathComponent("config"), encoding: .utf8)
        let aliases = config.components(separatedBy: "\n").filter { $0.hasPrefix("    HostKeyAlias ") }
            .map { String($0.dropFirst("    HostKeyAlias ".count)) }
        XCTAssertEqual(aliases.count, 2)
        // Corrupt one trusted pin at a time: target and intermediate jump. The
        // other network must remain connectable, including its existing session.
        for alias in aliases {
            let remove = Process()
            remove.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            remove.arguments = ["-R", alias, "-f", paths.knownHosts.path]
            remove.standardOutput = FileHandle.nullDevice; remove.standardError = FileHandle.nullDevice
            try remove.run(); remove.waitUntilExit()
            XCTAssertEqual(remove.terminationStatus, 0)
            let writer = try FileHandle(forWritingTo: paths.knownHosts)
            try writer.seekToEnd()
            try writer.write(contentsOf: Data("\(alias) \(fixture["wrong_key"] as! String)\n".utf8))
            try writer.close()
            let changed = try command(0, builder: accepting)
            XCTAssertTrue(changed.0 != 0 && changed.1.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
            XCTAssertTrue(changed.1.contains(alias))
            XCTAssertEqual(try command(1, builder: rejecting).0, 0)
            _ = try await clientB.list("/")
            try trusted.write(to: paths.knownHosts)
        }
        print("PASS 同一路径的目标或中间跳板指纹变化仍被拒绝，另一网络的连接保持正常")
    }
}
