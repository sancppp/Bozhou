import Foundation
import Darwin
import BozhouCore

enum IntegrationTests {
    private static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
            + TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
    }

    static func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime/integration")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
        let ports = json["ports"] as! [Int]
        let paths = try AppPaths(root: root.appendingPathComponent("client Application Support ' 中文 100%"))
        try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: paths.knownHosts)
        let askpass = root.appendingPathComponent("test-askpass")
        try """
        #!/bin/sh
        case "$1" in
            *yes/no*) printf '%s\\n' yes ;;
            *) printf '%s\\n' bozhou-test-only ;;
        esac

        """.write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        let identity = Identity(name: "测试密钥", privateKeyPath: root.appendingPathComponent("id_ed25519").path)
        let builder = ConnectionBuilder(paths: paths, askPass: askpass.path)
        var jump1 = Host(name: "跳板一", address: "127.0.0.1", port: ports[0], username: "jump1", authentication: .identity)
        jump1.identityID = identity.id
        var jump2 = Host(name: "跳板二", address: "127.0.0.1", port: ports[1], username: "jump2", authentication: .password)
        jump2.jumpHosts = [jump1.id]
        var host = Host(name: "测试目标", address: "127.0.0.1", port: ports[2], username: "tester", authentication: .identity)
        host.identityID = identity.id; host.jumpHosts = [jump2.id]; host.shell = "/bin/bash"
        let hosts = [jump1, jump2, host]
        let launch = try builder.build(host: host, hosts: hosts, identities: [identity], sftp: true)
        let client = SFTPClient(launch: launch)
        defer { client.cancel() }
        let home = try await client.connect()
        XCTAssertEqual(home, "/")
        print("PASS OpenSSH 私钥 → 密码跳板 → 私钥目标，两级跳板与 SFTP 协商（空格/引号/百分号路径）")
        let folder = "/验证-\(UUID().uuidString)"
        try await client.mkdir(folder)
        let local = root.appendingPathComponent("upload.bin")
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: local)
        let filename = "中文 空格 ' \" ; $ 文件.bin"
        try await client.upload(local: local, remote: folder + "/" + filename) { _, _ in }
        let entries = try await client.list(folder)
        XCTAssertEqual(entries.map(\.name), [filename])
        XCTAssertEqual(entries.first?.size, UInt64(payload.count))
        let second = SFTPClient(launch: try builder.build(host: jump1, hosts: hosts, identities: [identity], sftp: true))
        defer { second.cancel() }
        _ = try await second.connect()
        let remoteCopy = "/relay-\(UUID().uuidString).bin"
        try await client.copy(remote: folder + "/" + filename, to: second, path: remoteCopy, total: UInt64(payload.count)) { _, _ in }
        let returnCopy = folder + "/return.bin"
        try await second.copy(remote: remoteCopy, to: client, path: returnCopy, total: UInt64(payload.count)) { _, _ in }
        let relayDownload = root.appendingPathComponent("relay-\(UUID().uuidString).bin")
        try await client.download(remote: returnCopy, local: relayDownload, total: UInt64(payload.count)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: relayDownload), payload)
        do {
            try await client.copy(remote: folder + "/" + filename, to: second, path: remoteCopy, total: UInt64(payload.count)) { _, _ in }
            fail("服务器间传输不应覆盖已有文件")
        } catch {}
        let destinationFiles = try await second.list("/")
        XCTAssertTrue(!destinationFiles.contains { $0.name.hasPrefix(remoteCopy.dropFirst() + ".bozhou-") })
        try await second.remove(remoteCopy, directory: false)
        try await client.remove(returnCopy, directory: false)
        try FileManager.default.removeItem(at: relayDownload)
        print("PASS 独立服务器目录 A → B → A，双向流式传输逐字节一致；拒绝覆盖、清理临时文件")
        let target = root.appendingPathComponent("download-\(UUID().uuidString).bin")
        try await client.download(remote: folder + "/" + filename, local: target, total: UInt64(payload.count)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: target), payload)
        try FileManager.default.removeItem(at: target)
        try await client.rename(folder + "/" + filename, to: folder + "/renamed.bin")
        try await client.remove(folder + "/renamed.bin", directory: false)
        let remaining = try await client.list(folder)
        XCTAssertTrue(remaining.isEmpty)
        try await client.remove(folder, directory: true)
        print("PASS SFTP 中文/空格/引号文件名，20 万字节上传下载一致、重命名、删除、目录操作")
        do {
            _ = try await client.list("/does-not-exist")
            fail("不存在的目录应报错")
        } catch { print("PASS SFTP 远程错误可恢复") }
        _ = try await client.list("/")
        client.cancel()
        do { _ = try await client.list("/"); fail("取消后不能继续请求") }
        catch { print("PASS SFTP 取消与管道退出") }
        let idleCPUStart = processCPUTime()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(processCPUTime() - idleCPUStart < 0.1)
        print("PASS SFTP stderr EOF 后停止文件句柄监听")

        let ssh = try builder.build(host: host, hosts: hosts, identities: [identity])
        defer { ssh.cleanup() }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: ssh.executable)
        process.arguments = ["-E", ssh.logURL!.path, "-F", ssh.directory.appendingPathComponent("config").path, "-T", "bz-2", "printf 'ssh-chain-ok'"]
        process.environment = ssh.environment; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ssh-chain-ok")
        let rawLog = try String(contentsOf: ssh.logURL!, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("Authenticated to"))
        print("PASS SSH 两级跳板远程命令真实执行")

        let passwordBuilder = ConnectionBuilder(paths: paths, askPass: URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("BozhouAskPass").path)
        let passwordStore = try Store(url: paths.database)
        var passwordHosts = hosts
        for index in passwordHosts.indices {
            passwordHosts[index].authentication = .password
            passwordHosts[index].password = ["jump-one-test-only", "bozhou-test-only", "target-test-only"][index]
            try passwordStore.save(passwordHosts[index])
        }
        for _ in 0..<2 {
            let cached = try passwordBuilder.build(host: passwordHosts[2], hosts: passwordHosts, identities: [], sftp: true)
            defer { cached.cleanup() }
            let command = Process(), response = Pipe()
            command.executableURL = URL(fileURLWithPath: cached.executable)
            command.arguments = ["-F", cached.directory.appendingPathComponent("config").path,
                                 "-T", "bz-2", "printf 'password-chain-ok'"]
            command.environment = cached.environment.merging(["BOZHOU_ASKPASS_NONINTERACTIVE": "1"]) { _, new in new }
            command.standardOutput = response; command.standardError = FileHandle.nullDevice
            try command.run()
            let data = response.fileHandleForReading.readDataToEndOfFile(); command.waitUntilExit()
            XCTAssertEqual(command.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "password-chain-ok")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cached.directory.path)
                .filter { $0.hasPrefix("password-attempt-") }.count, 3)
        }
        var sftpLaunch = try passwordBuilder.build(host: passwordHosts[2], hosts: passwordHosts, identities: [], sftp: true)
        sftpLaunch.environment["BOZHOU_ASKPASS_NONINTERACTIVE"] = "1"
        let cachedClient = SFTPClient(launch: sftpLaunch)
        _ = try await cachedClient.connect()
        _ = try await cachedClient.list("/")
        cachedClient.cancel()
        print("PASS 三台同地址不同端口、不同密码：真实 AskPass 两次自动连接与 SFTP 均无弹窗")

        var forwarded = host
        forwarded.forwards = [LocalForward(localPort: json["forward_port"] as! Int, remotePort: json["http_port"] as! Int)]
        let forwardLaunch = try builder.build(host: forwarded, hosts: hosts, identities: [identity])
        defer { forwardLaunch.cleanup() }
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: forwardLaunch.executable)
        tunnel.arguments = Array(forwardLaunch.arguments.dropLast(3)) + ["-N", "bz-2"]
        tunnel.environment = forwardLaunch.environment
        tunnel.standardOutput = FileHandle.nullDevice; tunnel.standardError = FileHandle.nullDevice
        try tunnel.run()
        defer { if tunnel.isRunning { tunnel.terminate(); tunnel.waitUntilExit() } }
        let curl = Process(), response = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-fsS", "--max-time", "2", "--retry", "5", "--retry-connrefused", "--retry-delay", "1", "--retry-max-time", "8",
                          "http://127.0.0.1:\(forwarded.forwards[0].localPort)"]
        curl.standardOutput = response; curl.standardError = FileHandle.nullDevice
        try curl.run()
        let responseData = response.fileHandleForReading.readDataToEndOfFile(); curl.waitUntilExit()
        XCTAssertEqual(curl.terminationStatus, 0)
        XCTAssertEqual(String(decoding: responseData, as: UTF8.self), "forwarding-ok\n")
        let conflict = Process()
        conflict.executableURL = tunnel.executableURL; conflict.arguments = tunnel.arguments
        conflict.environment = tunnel.environment; conflict.standardOutput = FileHandle.nullDevice; conflict.standardError = FileHandle.nullDevice
        try conflict.run(); conflict.waitUntilExit()
        XCTAssertTrue(conflict.terminationStatus != 0)
        tunnel.terminate(); tunnel.waitUntilExit()
        print("PASS 两级跳板端口转发 HTTP 响应一致，本地端口冲突时立即失败")

        let trustedKnownHosts = try Data(contentsOf: paths.knownHosts)
        try Data(contentsOf: root.appendingPathComponent("wrong_known_hosts")).write(to: paths.knownHosts)
        let rejected = Process(), rejection = Pipe()
        rejected.executableURL = URL(fileURLWithPath: ssh.executable)
        rejected.arguments = process.arguments
        rejected.environment = ssh.environment
        rejected.standardOutput = rejection; rejected.standardError = rejection
        try rejected.run()
        let rejectionData = rejection.fileHandleForReading.readDataToEndOfFile()
        rejected.waitUntilExit()
        XCTAssertTrue(rejected.terminationStatus != 0)
        let rejectionLog = try String(contentsOf: ssh.logURL!, encoding: .utf8)
        XCTAssertTrue((String(decoding: rejectionData, as: UTF8.self) + rejectionLog).contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        try trustedKnownHosts.write(to: paths.knownHosts)
        print("PASS 主机指纹变化时 OpenSSH 拒绝连接")

        try await RouteIntegrationTests.run(root: root, fixture: json, identity: identity, askpass: askpass.path)

        // Prepare explicit test-only app data for UI verification; production data remains empty.
        let uiPaths = try AppPaths(root: root.appendingPathComponent("ui-app"))
        try trustedKnownHosts.write(to: uiPaths.knownHosts)
        let store = try Store(url: uiPaths.database)
        for item in try store.list(Host.self) { try store.delete(Host.self, id: item.id) }
        for item in try store.list(Identity.self) { try store.delete(Identity.self, id: item.id) }
        for item in try store.list(Snippet.self) { try store.delete(Snippet.self, id: item.id) }
        try store.save(identity)
        jump1.group = "本地验证"; jump2.group = "本地验证"; host.group = "本地验证"
        // UI fixture uses keys for all hops, password path already tested through OpenSSH above.
        jump2.authentication = .identity; jump2.identityID = identity.id
        for item in [jump1, jump2, host] { try store.save(item) }
        try store.save(Snippet(name: "系统信息", command: "uname -a", detail: "查看系统与内核"))
    }
}
