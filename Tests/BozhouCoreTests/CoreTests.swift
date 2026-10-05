import Foundation
@testable import BozhouCore

final class CoreTests {
    var root: URL!
    func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["BOZHOU_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/.runtime/tests"
        root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testPersistenceAndHistoryRetention() throws {
        let path = root.appendingPathComponent("test.sqlite")
        let store = try Store(url: path)
        var host = Host(name: "中文主机 ' \"", address: "::1")
        host.environment = ["A": "hello\n'中文"]
        try store.save(host)
        XCTAssertEqual(try Store(url: path).list(Host.self), [host])
        host.port = 2222; try store.save(host)
        XCTAssertEqual(try store.list(Host.self).count, 1)
        for index in 0..<5 {
            try store.save(Interaction(hostName: "test", sessionID: UUID(), shell: "#!/bin/bash", command: "\(index)"))
        }
        let pin = Pin(try XCTUnwrap(store.list(Interaction.self).first))
        try store.save(pin)
        try store.trimHistory(limit: 2)
        XCTAssertEqual(try store.list(Interaction.self).count, 2)
        try store.clearHistory()
        XCTAssertEqual(try store.list(Pin.self), [pin])
        try store.delete(Host.self, id: host.id)
        XCTAssertTrue(try store.list(Host.self).isEmpty)
    }
    func testChainPreservesHopSettingsAndIsolation() throws {
        let paths = try AppPaths(root: root)
        let builder = ConnectionBuilder(paths: paths, askPass: "/not-used")
        let first = Host(name: "跳板一", address: "jump.example", port: 2222, username: "jump", authentication: .password)
        var second = Host(name: "跳板二", address: "second.example", port: 2200, username: "ops")
        second.jumpHosts = [first.id]
        var final = Host(name: "目标", address: "host.example", username: "server")
        final.jumpHosts = [second.id]
        XCTAssertEqual(try builder.chain(for: final, hosts: [first, second]).map(\.id), [first.id, second.id])
        let launch = try builder.build(host: final, hosts: [first, second], identities: [])
        defer { launch.cleanup() }
        let text = try String(contentsOf: launch.directory.appendingPathComponent("config"))
        XCTAssertTrue(text.contains("'[%h]:%p' bz-0"))
        XCTAssertTrue(text.contains("'[%h]:%p' bz-1"))
        XCTAssertTrue(text.contains("ProxyCommand '/usr/bin/env'"))
        XCTAssertTrue(!text.contains("ProxyCommand exec "))
        XCTAssertTrue(text.contains("User jump\n    Port 2222"))
        XCTAssertTrue(text.contains("GlobalKnownHostsFile /dev/null"))
        XCTAssertTrue(text.contains("StrictHostKeyChecking ask"))
        XCTAssertEqual(launch.environment["SSH_ASKPASS_REQUIRE"], "force")
    }
    func testRejectsCyclesAndInjection() throws {
        let builder = ConnectionBuilder(paths: try AppPaths(root: root), askPass: "")
        var host = Host(name: "bad", address: "host\nProxyCommand touch /tmp/oops")
        XCTAssertThrowsError(try builder.validate(host, hosts: [], identities: []))
        host.address = "localhost"; host.jumpHosts = [host.id]
        XCTAssertThrowsError(try builder.chain(for: host, hosts: [host]))
        host.jumpHosts = []; host.environment = ["A;bad": "1"]
        XCTAssertThrowsError(try builder.validate(host, hosts: [], identities: []))
        host.address = "::1"; host.environment = [:]
        var proxy = ProxyConfiguration(); proxy.host = "::1"
        host.proxy = proxy
        let launch = try builder.build(host: host, hosts: [], identities: [])
        defer { launch.cleanup() }
        let config = try String(contentsOf: launch.directory.appendingPathComponent("config"))
        XCTAssertTrue(config.contains("-x [::1]:1080"))
        XCTAssertEqual(shellQuote("x'y"), "'x'\\''y'")
    }
    func testPasswordMigrationAndCacheIsolation() throws {
        let paths = try AppPaths(root: root)
        let store = try Store(url: paths.database)
        var host = Host(name: "目标", address: "localhost", authentication: .password)
        XCTAssertEqual(host.username, "root")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as! [String: Any]
        old.removeValue(forKey: "password"); old.removeValue(forKey: "username")
        let migrated = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.password, ""); XCTAssertEqual(migrated.username, "root")
        host.password = "target-password"
        var jump = Host(name: "跳板", address: "localhost", authentication: .password)
        jump.password = "jump-password"
        try store.save(host); try store.save(jump)
        var env = ["BOZHOU_AUTH_DATABASE": paths.database.path, "BOZHOU_AUTH_SESSION": root.path,
                   "BOZHOU_AUTH_HOST": host.id.uuidString]
        let cache = try XCTUnwrap(PasswordCache(environment: env, prompt: "root@localhost's password: "))
        XCTAssertEqual(cache.takeSavedPassword(), host.password)
        XCTAssertNil(cache.takeSavedPassword())
        for prompt in ["Enter passphrase for key:", "Verification code:", "New password:", "One-time password:"] {
            XCTAssertNil(try PasswordCache(environment: env, prompt: prompt))
        }
        host.notes = "concurrent change"; try store.save(host)
        try cache.save("corrected-password")
        let saved = try XCTUnwrap(store.list(Host.self).first { $0.id == host.id })
        XCTAssertEqual(saved.notes, host.notes); XCTAssertEqual(saved.password, "corrected-password")
        env["BOZHOU_AUTH_HOST"] = jump.id.uuidString
        XCTAssertEqual(try PasswordCache(environment: env, prompt: "Password:")?.takeSavedPassword(), jump.password)
    }
    func testKerberosConfig() throws {
        let host = Host(name: "devbox", address: "localhost", username: "remote-user", authentication: .kerberos)
        let launch = try ConnectionBuilder(paths: AppPaths(root: root), askPass: "").build(host: host, hosts: [], identities: [])
        defer { launch.cleanup() }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", launch.directory.appendingPathComponent("config").path, "bz-0"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for line in ["gssapiauthentication yes", "gssapidelegatecredentials no", "preferredauthentications gssapi-with-mic",
                     "passwordauthentication no", "kbdinteractiveauthentication no", "user remote-user"] {
            XCTAssertTrue(output.contains(line))
        }
    }
    func testRecorderEveryByteBoundaryAndOutputCap() throws {
        let recorder = InteractionRecorder(token: "abc", hostID: nil, hostName: "测试", sessionID: UUID(), maximumOutput: 8)
        var captured: [Interaction] = []
        var ready = ""
        recorder.onInteraction = { captured.append($0) }
        recorder.onReady = { ready = $0 }
        let text = "密码提示\u{1b}]777;bozhou;abc;ready;bash\u{7}\u{1b}]777;bozhou;abc;command;bash;echo 中文%3B%25%0A\u{7}0123456789\u{1b}]777;bozhou;abc;end;7\u{7}$ "
        var visible: [UInt8] = []
        for byte in text.utf8 { visible += recorder.feed([byte]) }
        XCTAssertEqual(ready, "bash")
        XCTAssertEqual(String(decoding: visible, as: UTF8.self), "密码提示0123456789$ ")
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].command, "echo 中文;%\n")
        XCTAssertEqual(captured[0].output, "01234567")
        XCTAssertEqual(captured[0].exitCode, 7)
        XCTAssertTrue(captured[0].truncated)
    }
    func testRecorderIgnoresForeignTokenAndFlushesOnDisconnect() {
        let recorder = InteractionRecorder(token: "ours", hostID: nil, hostName: "test", sessionID: UUID())
        var records: [Interaction] = []
        recorder.onInteraction = { records.append($0) }
        _ = recorder.feed(Array("\u{1b}]777;bozhou;other;command;bash;x\u{7}".utf8))
        XCTAssertTrue(records.isEmpty)
        _ = recorder.feed(Array("\u{1b}]777;bozhou;ours;command;bash;x\u{7}中文".utf8))
        recorder.finish()
        XCTAssertEqual(records.first?.output, "中文")
        XCTAssertNil(records.first?.exitCode)
        _ = recorder.feed(Array("\u{1b}]777;bozhou;ours;command;/bin/bash;exit 7\u{7}".utf8))
        recorder.finish(exitCode: 7)
        XCTAssertEqual(records.last?.exitCode, 7)
    }
    func testPacketHandlesUnicodeAndRejectsTruncation() throws {
        var packet = Packet()
        packet.uint(0x1234abcd); packet.long(0x12345678abcdef01); packet.string("中文 ' \n 文件")
        XCTAssertEqual(try packet.readUInt(), 0x1234abcd)
        XCTAssertEqual(try packet.readLong(), 0x12345678abcdef01)
        XCTAssertEqual(try packet.readString(), "中文 ' \n 文件")
        XCTAssertThrowsError(try packet.readByte())
        var short = Packet(data: Data([0, 0, 0, 9, 1]))
        XCTAssertThrowsError(try short.readBytes())
    }
    func testRealBashAndZshShellHooks() throws {
        for shell in ["bash", "zsh"] {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let rcDirectory = root.appendingPathComponent(shell)
            try FileManager.default.createDirectory(at: rcDirectory, withIntermediateDirectories: true)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/\(shell)")
            var environment = ProcessInfo.processInfo.environment
            environment["HISTFILE"] = "/dev/null"
            environment["__bp_delay_install"] = "1" // Permit non-TTY input for this bounded shell test.
            if shell == "bash" {
                let rc = rcDirectory.appendingPathComponent("bashrc")
                let script = ShellIntegration.bash(token: token)
                    .replacingOccurrences(of: "[[ -r ~/.bashrc ]] && source ~/.bashrc", with: "HISTFILE=/dev/null\nPROMPT_COMMAND='printf original-prompt-hook'")
                try (script + "\n__bp_install\n").write(to: rc, atomically: true, encoding: .utf8)
                process.arguments = ["--noprofile", "--rcfile", rc.path, "-i"]
            } else {
                try ShellIntegration.zsh(token: token).write(to: rcDirectory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
                environment["ZDOTDIR"] = rcDirectory.path
                environment["BOZHOU_OLD_ZDOTDIR"] = root.path
                process.arguments = ["-d", "-i"]
            }
            process.environment = environment; process.currentDirectoryURL = root
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("printf '中文 shell-ok\\n'\nfalse\nexit\n".utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if shell == "bash" { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("original-prompt-hook")) }
            let recorder = InteractionRecorder(token: token, hostID: nil, hostName: "test", sessionID: UUID())
            var records: [Interaction] = []
            recorder.onInteraction = { records.append($0) }
            _ = recorder.feed(Array(data)); recorder.finish()
            XCTAssertTrue(records.contains { $0.command.contains("printf") && $0.output.contains("中文 shell-ok") && $0.exitCode == 0 })
            XCTAssertTrue(records.contains { $0.command == "false" && $0.exitCode == 1 })
        }
    }

    func testSettingsMigrationAndReconnectPolicy() throws {
        let old = Data(#"{"fontSize":18,"appearance":"dark","saveHistory":false,"notifications":false,"historyLimit":500}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings.fontName, "Menlo-Regular")
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertEqual(settings.appearance, "dark")
        XCTAssertNil(settings.terminalBackgroundHex)
        XCTAssertTrue(settings.expandedHostGroups.isEmpty)
        var customized = settings
        customized.terminalBackgroundHex = "#E7EBEF"
        customized.expandedHostGroups = ["生产", "生产/华北", "开发"]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(customized)), customized)
        let database = root.appendingPathComponent("settings.sqlite")
        try Store(url: database).saveSettings(customized)
        XCTAssertEqual(try Store(url: database).loadSettings(), customized)
        XCTAssertTrue(try Store(url: root.appendingPathComponent("other.sqlite")).loadSettings().expandedHostGroups.isEmpty)
        XCTAssertTrue(settings.autoReconnect)
        XCTAssertTrue(!settings.saveHistory)
        XCTAssertEqual(AppSettings().appearance, "light")
        var policy = ReconnectPolicy()
        for delay in [2, 4, 8, 16, 30] {
            XCTAssertEqual(policy.nextDelay(exitCode: 255, output: "Connection reset", enabled: true), delay)
        }
        XCTAssertNil(policy.nextDelay(exitCode: 255, output: "", enabled: true))
        policy.reset()
        for message in ["Permission denied", "REMOTE HOST IDENTIFICATION HAS CHANGED", "Host key verification failed"] {
            XCTAssertNil(policy.nextDelay(exitCode: 255, output: message, enabled: true))
        }
        XCTAssertNil(policy.nextDelay(exitCode: 0, output: "", enabled: true))
        XCTAssertNil(policy.nextDelay(exitCode: 255, output: "", enabled: false))
        XCTAssertEqual(policy.nextDelay(exitCode: nil, output: "", enabled: true), 2)
    }

    func testDiffAlignmentAndBoundedLargeOutput() {
        for (old, new) in [("a\n旧值\nc\n", "a\n新值\n增加\nc\n"), ("相同", "相同"), ("", "新增"), ("删除", "")] {
            let diff = OutputDiff(old, new)
            XCTAssertEqual(diff.left.count, diff.right.count)
            XCTAssertEqual(diff.left.filter { $0.kind != .gap }.map(\.text).joined(separator: "\n"), old)
            XCTAssertEqual(diff.right.filter { $0.kind != .gap }.map(\.text).joined(separator: "\n"), new)
            for (left, right) in zip(diff.left, diff.right) where left.kind == .equal && right.kind == .equal {
                XCTAssertEqual(left.text, right.text)
            }
        }
        let diff = OutputDiff("a\n旧值\nc", "a\n新值\n增加\nc")
        XCTAssertEqual(diff.removed, 1); XCTAssertEqual(diff.added, 2)
        let large = (0..<5000).map(String.init).joined(separator: "\n")
        let bounded = OutputDiff(large, large + "\nextra")
        XCTAssertEqual(bounded.added, 1); XCTAssertEqual(bounded.removed, 0)
    }

    func testStructuredLogFilteringAndLegacyRead() throws {
        let log = AppLog(paths: try AppPaths(root: root))
        try "2026-10-04T01:00:00Z 旧日志\n".write(to: log.url, atomically: true, encoding: .utf8)
        log.write("连接成功 中文", category: "连接")
        log.write("认证失败", level: .error, category: "连接")
        let entries = log.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.filter { $0.matches(search: "中文", level: nil, category: "") }.count, 1)
        XCTAssertEqual(entries.filter { $0.matches(search: "", level: .error, category: "连接") }.count, 1)
        XCTAssertEqual(entries.last?.message, "旧日志")
    }
    func testFoldersMetadataAndForwardingMigration() throws {
        var host = Host(name: "三期", address: "127.0.0.1", group: "生产/华北")
        let encoded = try JSONEncoder().encode(host)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["createdAt", "lastLoginAt", "systemProfile", "forwards"] { old.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.group, host.group); XCTAssertTrue(migrated.forwards.isEmpty)
        XCTAssertNil(migrated.lastLoginAt)
        XCTAssertEqual(try HostTree.normalize("/生产/华北/"), "生产/华北")
        XCTAssertEqual(HostTree.ancestors("生产/华北/应用"), ["生产", "生产/华北", "生产/华北/应用"])
        XCTAssertTrue(!HostTree.contains("生产2/华北", in: "生产"))
        XCTAssertThrowsError(try HostTree.normalize("生产/../华北"))
        let paths = try AppPaths(root: root)
        let builder = ConnectionBuilder(paths: paths, askPass: "")
        host.forwards = [LocalForward(remoteHost: "::1")]
        let ssh = try builder.build(host: host, hosts: [host], identities: [])
        defer { ssh.cleanup() }
        XCTAssertTrue(ssh.arguments.contains("127.0.0.1:58080:[::1]:80"))
        XCTAssertTrue(ssh.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(ssh.logURL?.path.hasSuffix(".ssh.log") == true)
        let sftp = try builder.build(host: host, hosts: [host], identities: [], sftp: true)
        defer { sftp.cleanup() }
        XCTAssertTrue(!sftp.arguments.contains("-L"))
        host.forwards.append(LocalForward())
        XCTAssertThrowsError(try builder.validate(host, hosts: [host], identities: []))
    }
    func testPinDeduplicationAndWorkspaceCopy() throws {
        let paths = try AppPaths(root: root.appendingPathComponent("source"))
        let store = try Store(url: paths.database)
        let first = Interaction(hostName: "A", sessionID: UUID(), shell: "bash", command: "pwd", output: "/tmp\n")
        let other = Interaction(hostName: "B", sessionID: UUID(), shell: "zsh", command: "pwd", output: "/tmp\n")
        try store.save(Pin(first)); try store.save(Pin(other))
        XCTAssertEqual(try store.list(Pin.self).count, 1)
        var different = other; different.output = "/var\n"
        try store.save(Pin(different))
        XCTAssertEqual(try store.list(Pin.self).count, 2)
        try store.save(HostFolder(path: "生产/华北"))
        try store.save(Host(name: "sample", address: "localhost", group: "生产/华北"))
        var settings = AppSettings()
        settings.expandedHostGroups = ["生产", "生产/华北"]
        try store.saveSettings(settings)
        try Data("test fingerprint".utf8).write(to: paths.knownHosts)
        let copied = try WorkspaceLocation.copy(store: store, from: paths, to: root.appendingPathComponent("target"))
        let loaded = try Store(url: copied.database)
        XCTAssertEqual(try loaded.list(Pin.self), try store.list(Pin.self))
        XCTAssertEqual(try loaded.list(Host.self), try store.list(Host.self))
        XCTAssertEqual(try loaded.list(HostFolder.self), try store.list(HostFolder.self))
        XCTAssertEqual(try loaded.loadSettings(), settings)
        XCTAssertEqual(try Data(contentsOf: copied.knownHosts), try Data(contentsOf: paths.knownHosts))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.database.path))
        XCTAssertThrowsError(try WorkspaceLocation.copy(store: store, from: paths, to: copied.root))
        XCTAssertThrowsError(try WorkspaceLocation.copy(store: store, from: paths, to: paths.root.appendingPathComponent("nested")))
    }
    func testReadOnlySystemProbe() throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SystemProbe.script(token: "system-test")]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let recorder = InteractionRecorder(token: "system-test", hostID: nil, hostName: "test", sessionID: UUID())
        var profile: SystemProfile?
        var interactions = 0
        recorder.onSystemProfile = { profile = $0 }
        recorder.onInteraction = { _ in interactions += 1 }
        var visible: [UInt8] = []
        for byte in data { visible += recorder.feed([byte]) }
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(profile?.operatingSystem.contains("macOS") == true)
        XCTAssertTrue(profile?.kernel.contains("Darwin") == true)
        XCTAssertTrue(profile?.cpu.isEmpty == false)
        XCTAssertTrue(profile?.hostname?.isEmpty == false)
        let oldProfile = Data(#"{"collectedAt":0,"operatingSystem":"Linux","kernel":"6.1","cpu":"x86","memory":"1G"}"#.utf8)
        let migrated = try JSONDecoder().decode(SystemProfile.self, from: oldProfile)
        XCTAssertNil(migrated.hostname)
        XCTAssertEqual(migrated.kernel, "6.1")
        let sections = "[os]\nLinux\n[memory]\n1G\n[future]\nnot-memory\n[hostname]\nserver-a\n[kernel]\n6.1\n[cpu]\nx86\n"
        let parsed = SystemProbe.parse(Data(sections.utf8).base64EncodedString())
        XCTAssertEqual(parsed?.hostname, "server-a")
        XCTAssertEqual(parsed?.memory, "1G")
        XCTAssertEqual(parsed?.kernel, "6.1")
        XCTAssertEqual(parsed?.cpu, "x86")
        let legacy = SystemProbe.parse(Data("[os]\nLinux\n[kernel]\n5.10\n[cpu]\nx86\n[memory]\n2G\n".utf8).base64EncodedString())
        XCTAssertNil(legacy?.hostname)
        XCTAssertEqual(legacy?.memory, "2G")
        XCTAssertEqual(try JSONDecoder().decode(SystemProfile.self, from: JSONEncoder().encode(parsed!)), parsed)
        XCTAssertEqual(interactions, 0)
    }
}
