import Foundation
import BozhouCore

// Command Line Tools ship no XCTest. These assertions keep tests executable without full Xcode.
var failures = 0
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1; print("FAIL \(file):\(line): \(message)")
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { fail("期望 true", file: file, line: line) } } catch { fail("\(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do {
        let left = try lhs(), right = try rhs()
        if left != right { fail("\(left) != \(right)", file: file, line: line) }
    } catch { fail("\(error)", file: file, line: line) }
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { fail("期望 nil", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body(); fail("期望错误", file: file, line: line) } catch {}
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "意外 nil"]) }
    return value
}

@main
struct TestRunner {
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--probe-host"), CommandLine.arguments.count > index + 2 {
            do {
                try await LiveProbe.run(workspace: CommandLine.arguments[index + 1], name: CommandLine.arguments[index + 2])
            } catch { fail(error.localizedDescription) }
            exit(failures == 0 ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-shells"), CommandLine.arguments.count > index + 1 {
            let shells = Set(["/bin/bash", "/bin/zsh", ProcessInfo.processInfo.environment["BOZHOU_TEST_BASH"] ?? "/bin/bash"])
            var commands = Dictionary(uniqueKeysWithValues: shells.map { shell in
                var host = BozhouCore.Host(); host.shell = shell
                return (shell, ShellIntegration.bootstrap(host: host, token: "pty-test"))
            })
            var local = BozhouCore.Host(); local.shell = "/bin/zsh"
            commands["local-zsh"] = ShellIntegration.bootstrap(host: local, token: "pty-test", local: true)
            do {
                try JSONSerialization.data(withJSONObject: commands).write(
                    to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            } catch { fail(error.localizedDescription) }
            exit(failures == 0 ? 0 : 1)
        }
        let test = CoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("双语资源、插值安全、英语默认与设置迁移", test.testLocalizationAndLanguageMigration),
            ("SQLite 持久化、更新、历史裁剪与独立收藏", test.testPersistenceAndHistoryRetention),
            ("多跳认证参数与 SSH 配置隔离", test.testChainPreservesHopSettingsAndIsolation),
            ("密码迁移、逐级复用、失败回退与并发字段保留", test.testPasswordMigrationAndCacheIsolation),
            ("Kerberos 配置由真实 OpenSSH 解析", test.testKerberosConfig),
            ("循环引用与输入注入拦截", test.testRejectsCyclesAndInjection),
            ("OSC 逐字节分片、命令和输出限额", test.testRecorderEveryByteBoundaryAndOutputCap),
            ("忽略其他会话标记并保留中断输出", test.testRecorderIgnoresForeignTokenAndFlushesOnDisconnect),
            ("输出尾部环形缓存、跨界分片与快照隔离", test.testRecorderTailAcrossWrapsAndChunks),
            ("异常上下文脱敏、权限、体积和保留数量", test.testTerminalDiagnosticPersistence),
            ("SFTP 二进制编码、中文与截断校验", test.testPacketHandlesUnicodeAndRejectsTruncation),
            ("真实 bash / zsh 交互边界与退出码", test.testRealBashAndZshShellHooks),
            ("旧设置迁移、重连退避与认证失败停止", test.testSettingsMigrationAndReconnectPolicy),
            ("主机名称缩略、旧交互兼容与 hostname 快照", test.testHostDisplayAndInteractionMigration),
            ("输出差异对齐与大输出限额", test.testDiffAlignmentAndBoundedLargeOutput),
            ("结构化日志过滤与旧日志读取", test.testStructuredLogFilteringAndLegacyRead),
            ("文件夹路径、旧主机迁移与转发隔离", test.testFoldersMetadataAndForwardingMigration),
            ("收藏内容去重与 WAL 数据迁移", test.testPinDeduplicationAndWorkspaceCopy),
            ("真实只读系统信息采集与协议解析", test.testReadOnlySystemProbe)
        ]
        for (name, run) in cases {
            let before = failures
            do { try test.setUpWithError(); try run(); try test.tearDownWithError() } catch { fail(error.localizedDescription) }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        if CommandLine.arguments.contains("--integration") {
            do { try await IntegrationTests.run() } catch { fail("集成测试：\(error)") }
        }
        print("验证结束：\(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
