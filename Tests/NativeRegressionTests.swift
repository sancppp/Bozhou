import AppKit
import SwiftUI
import BozhouCore

@main
struct NativeRegressionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        // Keep bindings alive exactly as a native text field's deferred callback does.
        let first = LocalForward(localPort: 10001)
        let second = LocalForward(localPort: 10002)
        var rows = [first, second]
        let binding = Binding(get: { rows }, set: { rows = $0 })
        let firstPort = binding.element(first).localPort
        let secondPort = binding.element(second).localPort
        rows.removeFirst()
        precondition(firstPort.wrappedValue == 10001)
        firstPort.wrappedValue = 11001
        precondition(rows == [second], "Late writes must neither resurrect a row nor alter its successor")
        secondPort.wrappedValue = 11002
        precondition(rows[0].localPort == 11002, "A surviving binding must follow its row after removal")
        rows.insert(first, at: 0)
        rows.swapAt(0, 1)
        firstPort.wrappedValue = 12001
        precondition(rows[1].localPort == 12001 && rows[0].localPort == 11002)
        rows.removeAll()
        secondPort.wrappedValue = 13002
        precondition(rows.isEmpty && secondPort.wrappedValue == 10002)
        print("PASS port-forward bindings: removed row, late read/write, shifted row, reorder, remove all")

        let model = try AppModel()
        let directory = model.paths.sessions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launch = SSHLaunch(executable: "/bin/sleep", arguments: ["20"], environment: [:],
                               directory: directory, token: "closed-test")
        let session = TerminalSession(host: nil, launch: launch, settings: AppSettings(), directory: model.workingDirectory)
        session.close(immediately: true)
        session.start()
        let running = session.terminal.process.running
        if running { session.terminal.terminate() }
        precondition(!running, "A closed session must not start a deferred PTY process")
        print("PASS closed terminal rejects delayed start")

        let browser = FileBrowserModel()
        let host = Host(name: "Cancelled fixture", address: "127.0.0.1", port: 1)
        browser.connect(model: model, host: host)
        browser.cancel()
        // Let the cancelled connect task return from transport.start/exchange.
        try await Task.sleep(for: .milliseconds(500))
        precondition(browser.status == "连接已关闭" && !browser.busy && !browser.connected && browser.error == nil,
                     "A cancelled connection must not publish its late error")
        print("PASS cancelled SFTP task cannot overwrite current state")
    }
}
