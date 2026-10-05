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

        try await testTerminalLifecycle(model)
        testFontAndNames(model)

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

    @MainActor static func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        precondition(condition(), "Timed out waiting for the isolated terminal")
    }

    @MainActor static func testTerminalLifecycle(_ model: AppModel) async throws {
        func launch(shell: String?, token: String = UUID().uuidString) throws -> SSHLaunch {
            let directory = model.paths.sessions.appendingPathComponent(token)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var host = Host(); host.shell = shell ?? ""
            let command = shell.map { _ in ShellIntegration.bootstrap(host: host, token: token, local: true) } ?? "exit 255"
            return SSHLaunch(executable: "/bin/sh", arguments: ["-c", command],
                             environment: ["HOME": directory.path, "ZDOTDIR": directory.path,
                                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"],
                             directory: directory, token: token)
        }
        for shell in ["/bin/bash", "/bin/zsh", "/bin/sh"] {
            for command in ["exit", "exit 7", "exit 255"] {
                let host = Host(name: "isolated", address: "127.0.0.1")
                let session = TerminalSession(host: host, launch: try launch(shell: shell), settings: AppSettings(), directory: model.workingDirectory)
                model.addSession(session)
                session.start()
                try await wait { session.connected || session.ended }
                precondition(session.connected)
                session.send("printf 'exit is only text\\n'", execute: true)
                try await Task.sleep(for: .milliseconds(100))
                precondition(!session.ended && model.sessions.contains { $0.id == session.id })
                session.send(command, execute: true)
                try await wait { !model.sessions.contains { $0.id == session.id } }
                precondition(!session.reconnecting && model.activeSession == nil && model.page == .hosts)
                if shell != "/bin/sh" {
                    precondition(model.history.contains { $0.sessionID == session.id && $0.command == command },
                                 "Closing a session must first save its final interaction")
                }
            }
        }
        // Local EOF, including the lifetime of the final pane, follows the same route.
        let local = TerminalSession(host: nil, launch: try launch(shell: "/bin/zsh"), settings: AppSettings(), directory: model.workingDirectory)
        model.addSession(local); local.start()
        try await wait { local.connected }
        local.terminal.send(source: local.terminal, data: [4][...])
        try await wait { model.sessions.isEmpty }
        print("PASS real bash/zsh/sh exit, exit 7, exit 255 and local EOF close tabs; command text does not")

        let retry = TerminalSession(host: Host(name: "offline", address: "127.0.0.1"),
                                    launch: try launch(shell: nil), settings: AppSettings(), directory: model.workingDirectory)
        retry.makeLaunch = { try launch(shell: nil) }
        model.addSession(retry)
        retry.start()
        for delay in [5, 10, 30, 60, 120] {
            try await wait { retry.ended }
            precondition(retry.reconnecting && retry.status.contains("\(delay) 秒后重试"))
            let old = retry.terminal
            retry.reconnect(manual: false)
            retry.processTerminated(source: old, exitCode: 0)
            precondition(model.sessions.contains { $0.id == retry.id }, "Stale process completion must not close the new session")
        }
        try await wait { retry.ended }
        precondition(!retry.reconnecting && retry.status.contains("请手动重新连接"))
        retry.reconnect()
        try await wait { retry.ended }
        precondition(retry.reconnecting && retry.status.contains("5 秒后重试"))
        retry.cancelReconnect()
        precondition(!retry.reconnecting)
        model.closeAll()
        print("PASS failed transports schedule 5/10/30/60/120, stop after five, reset on manual retry and ignore stale callbacks")

        var panes: [TerminalSession] = []
        for _ in 0..<3 {
            let pane = TerminalSession(host: nil, launch: try launch(shell: nil), settings: AppSettings(), directory: model.workingDirectory)
            model.addSession(pane); panes.append(pane)
        }
        model.activeSession = panes[0].id; model.splitSession = panes[1].id; model.focusedSession = panes[0].id
        model.closeSession(panes[0].id)
        precondition(model.activeSession == panes[1].id && model.splitSession == nil && model.commandSession?.id == panes[1].id)
        model.splitSession = panes[2].id; model.focusedSession = panes[2].id
        model.closeSession(panes[2].id)
        precondition(model.activeSession == panes[1].id && model.splitSession == nil && model.commandSession?.id == panes[1].id)
        model.closeAll()
        print("PASS closing either split pane keeps the surviving pane and keyboard focus")
    }

    @MainActor static func testFontAndNames(_ model: AppModel) {
        let launch = SSHLaunch(executable: "/bin/true", arguments: [], environment: [:], directory: model.paths.sessions.appendingPathComponent("font"), token: "font")
        let session = TerminalSession(host: nil, launch: launch, settings: AppSettings(), directory: model.workingDirectory)
        let other = TerminalSession(host: nil, launch: launch, settings: AppSettings(), directory: model.workingDirectory)
        model.addSession(session); model.addSession(other)
        model.activeSession = session.id; model.splitSession = other.id; model.focusedSession = other.id
        model.commandSession?.changeFontSize(by: 1)
        precondition(session.terminal.font.pointSize == 14 && other.terminal.font.pointSize == 15)
        var settings = AppSettings(); settings.appearance = "dark"
        other.apply(settings)
        precondition(other.terminal.font.pointSize == 15, "Theme changes must retain the session's zoom")
        other.changeFontSize(by: 100); precondition(other.terminal.font.pointSize == 36)
        other.changeFontSize(by: -100); precondition(other.terminal.font.pointSize == 10)
        settings.fontSize = 18; other.apply(settings)
        precondition(other.terminal.font.pointSize == 18, "An explicit font setting replaces temporary zoom")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = other.terminal
        window.makeFirstResponder(other.terminal)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "=",
                                    charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)!
        precondition(other.terminal.performKeyEquivalent(with: event))
        precondition(other.terminal.font.pointSize == 19)
        precondition(!session.terminal.performKeyEquivalent(with: event), "An unfocused terminal cannot consume the shortcut")
        window.orderOut(nil)
        model.closeAll()
        print("PASS font shortcuts target the focused pane, retain zoom across theme changes and clamp to 10–36 pt")

        let field = HostNameTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.frame.size.width = 600
        field.hostName = HostDisplayName(name: "ecs-shared-nat_proxy", hostname: "iv-yet1b78rggygp2fbqnpj")
        field.layout()
        precondition(field.stringValue == field.hostName.full)
        let compactWidth = (field.hostName.compact as NSString).size(withAttributes: [.font: field.font!]).width + 5
        field.frame.size.width = compactWidth
        field.layout()
        precondition(field.stringValue == field.hostName.compact)
        field.frame.size.width = 150; field.layout()
        precondition(field.stringValue.hasSuffix("(...fbqnpj)") && field.toolTip == field.hostName.full)
        print("PASS native host labels fit full names, then hostname suffixes, preserving tooltips")
    }
}
