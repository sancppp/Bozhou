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

        try await testSessionSwitching(model)
        try await testTerminalLifecycle(model)
        testFontAndNames(model)

        let browser = FileBrowserModel()
        let host = Host(name: "Cancelled fixture", address: "127.0.0.1", port: 1)
        browser.connect(model: model, host: host)
        browser.cancel()
        // Let the cancelled connect task return from transport.start/exchange.
        try await Task.sleep(for: .milliseconds(500))
        precondition(browser.status == "Connection closed" && !browser.busy && !browser.connected && browser.error == nil,
                     "A cancelled connection must not publish its late error")
        print("PASS cancelled SFTP task cannot overwrite current state")
        try await testLocalization(model)
    }

    @MainActor static func testLocalization(_ model: AppModel) async throws {
        precondition(model.settings.language == .english && Page.hosts.title == "Hosts")
        model.settings.language = .simplifiedChinese
        model.saveSettings()
        precondition(L10n.language == .english, "Language changes apply at the next launch")
        let relaunched = try AppModel()
        precondition(relaunched.settings.language == .simplifiedChinese && Page.hosts.title == "主机")
        for language in AppLanguage.allCases {
            L10n.configure(language)
            precondition(HostSort.folders.title == (language == .english ? "Folder name" : "文件夹名称"))
            precondition(FileBrowserModel().status == (language == .english ? "Not connected yet" : "尚未连接"))
            for page in Page.allCases {
                model.page = page
                let content = NSHostingView(rootView: RootView().environmentObject(model).environment(\.locale, language.locale))
                content.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
                content.layoutSubtreeIfNeeded()
                precondition(content.fittingSize.width <= 1100, "\(language) / \(page) exceeded the window width")
            }
            let browser = FileBrowserModel()
            browser.connect(model: model, host: Host(name: "fixture", address: "127.0.0.1", port: 1))
            browser.cancel()
            try await Task.sleep(for: .milliseconds(100))
            precondition(browser.error == nil && !browser.connected && !browser.busy)
        }
        model.settings.language = .english; model.saveSettings(); L10n.configure(.english)
        print("PASS English default, persisted Chinese on relaunch, bilingual pages and language-independent SFTP cancellation")
    }

    @MainActor static func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        precondition(condition(), "Timed out waiting for the isolated terminal")
    }

    @MainActor static func testSessionSwitching(_ model: AppModel) async throws {
        let content = NSHostingView(rootView: RootView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        defer { model.closeAll(); window.contentView = nil }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
        }
        var sessions: [TerminalSession] = []
        for index in 0..<2 {
            let directory = model.paths.sessions.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let launch = SSHLaunch(executable: "/bin/cat", arguments: [], environment: ["TERM": "xterm-256color"],
                                   directory: directory, token: "switch-\(index)")
            let session = TerminalSession(host: nil, launch: launch, settings: AppSettings(), directory: directory)
            model.addSession(session)
            try await settle()
            precondition(session.terminal.process.running)
            // Enough scrollback to expose accidental reflow through a zero-width layout.
            session.terminal.feed(text: (0..<150).map {
                "session-\(index)-line-\($0)-abcdefghijklmnopqrstuvwxyz-0123456789\r\n"
            }.joined())
            session.terminal.scroll(toPosition: 0)
            sessions.append(session)
        }
        var terminals = sessions.map(\.terminal)
        let pids = terminals.map { $0.process.shellPid }
        func check(_ step: String) {
            for (index, session) in sessions.enumerated() {
                let terminal = session.terminal
                let text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                precondition(terminal === terminals[index] && terminal.process.shellPid == pids[index] && terminal.process.running,
                             "\(step): switching must retain the terminal and live PTY")
                precondition(text.contains("session-\(index)-line-0-") && text.contains("session-\(index)-line-149-"),
                             "\(step): switching lost scrollback; dims=\(terminal.getTerminal().getDims()), bytes=\(text.utf8.count), head=\(text.prefix(120))")
            }
        }
        for _ in 0..<3 {
            model.activeSession = nil
            try await settle()
            check("workspace")
            for session in sessions {
                let scrollRow = session.terminal.getTerminal().buffer.yDisp
                let size = session.terminal.frame.size
                model.activeSession = session.id
                try await settle()
                precondition(session.terminal.window === window)
                if session.terminal.frame.size == size {
                    precondition(session.terminal.getTerminal().buffer.yDisp == scrollRow,
                                 "Switching tabs at the same size must retain the scrolled viewport")
                }
                check("tab")
            }
            model.activeSession = sessions[0].id
            for vertical in [false, true] {
                model.splitSession = sessions[1].id; model.splitVertical = vertical
                try await settle()
                check("split")
            }
            model.splitSession = nil
            try await settle()
            check("unsplit")
        }
        model.activeSession = nil
        try await settle()
        // Real PTY output must continue to arrive while its SwiftUI pane is absent.
        let command = "background-pty-output"
        sessions[0].send(command, execute: true)
        try await wait {
            String(decoding: sessions[0].terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains(command)
        }
        model.activeSession = sessions[0].id
        try await settle()
        check("background output")
        print("PASS tab/workspace/split switching retains scrollback, terminal identity, PID and background PTY output")

        terminals[0].feed(text: "\u{1b}[?1049h\u{1b}[?1hALTERNATE-SCREEN")
        let cursor = (terminals[0].getTerminal().buffer.x, terminals[0].getTerminal().buffer.y)
        sessions[0].apply(AppSettings())
        model.activeSession = nil
        try await settle()
        model.activeSession = sessions[0].id
        try await settle()
        precondition(terminals[0].getTerminal().isCurrentBufferAlternate && terminals[0].getTerminal().applicationCursor)
        precondition((terminals[0].getTerminal().buffer.x, terminals[0].getTerminal().buffer.y) == cursor)
        precondition(String(decoding: terminals[0].getTerminal().getBufferAsData(), as: UTF8.self).contains("ALTERNATE-SCREEN"))
        terminals[0].feed(text: "\u{1b}[?1049l")
        check("alternate screen")
        print("PASS alternate screen, cursor and application mode survive remounting and unchanged settings")

        weak var releasedSession: TerminalSession?
        weak var releasedTerminal: RecordingTerminalView?
        weak var releasedProcess: AnyObject?
        releasedSession = sessions[0]; releasedTerminal = terminals[0]; releasedProcess = terminals[0].process
        model.closeAll()
        sessions.removeAll(); terminals.removeAll()
        try await settle()
        try await wait { releasedSession == nil && releasedTerminal == nil && releasedProcess == nil }
        print("PASS closing mounted sessions releases session, terminal and PTY objects")
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
                try await wait { session.ended }
                if command == "exit" {
                    try await wait { !model.sessions.contains { $0.id == session.id } }
                    precondition(!session.reconnecting && model.activeSession == nil && model.page == .hosts)
                } else {
                    precondition(model.sessions.contains { $0.id == session.id } && !session.reconnecting)
                    precondition(session.diagnosticURL != nil, "Nonzero exits must retain their diagnostic context")
                }
                if shell != "/bin/sh" {
                    precondition(model.history.contains { $0.sessionID == session.id && $0.command == command },
                                 "Closing a session must first save its final interaction")
                }
                model.closeAll()
            }
        }
        // Local EOF, including the lifetime of the final pane, follows the same route.
        let local = TerminalSession(host: nil, launch: try launch(shell: "/bin/zsh"), settings: AppSettings(), directory: model.workingDirectory)
        model.addSession(local); local.start()
        try await wait { local.connected }
        local.terminal.send(source: local.terminal, data: [4][...])
        try await wait { model.sessions.isEmpty }
        print("PASS real bash/zsh/sh exit and EOF close tabs; nonzero exits retain context without retry")

        // A real child shell crash must keep the tab and persist the final command/output.
        for shell in ["/bin/bash", "/bin/zsh"] {
            let crash = TerminalSession(host: nil, launch: try launch(shell: shell), settings: AppSettings(), directory: model.workingDirectory)
            model.addSession(crash); crash.start()
            try await wait { crash.connected }
            crash.send("ulimit -c 0; printf 'crash-context-final\\n'; kill -ABRT $$", execute: true)
            try await wait { crash.ended }
            precondition(model.sessions.contains { $0.id == crash.id } && !crash.reconnecting)
            let report = try Data(contentsOf: crash.diagnosticURL!)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let context = try decoder.decode(TerminalDiagnostic.self, from: report)
            precondition(context.shellExitCode == 134 && context.processExitCode == 134)
            precondition(context.terminalTail.contains("crash-context-final"))
            precondition(context.interactions.first?.command.contains("kill -ABRT") == true)
            let saved = crash.diagnosticURL!
            model.closeAll()
            precondition(FileManager.default.fileExists(atPath: saved.path), "Closing a pane cannot delete its report")
        }
        print("PASS actual bash/zsh SIGABRT keeps pane, final command/output and persistent exit context")

        // Exiting immediately after a large write must drain queued PTY output before saving.
        for _ in 0..<5 {
            let token = UUID().uuidString
            var burstLaunch = try launch(shell: nil, token: token)
            burstLaunch.arguments = ["-c", "awk 'BEGIN { for(i=0;i<15000;i++) print \"burst-output-line\"; print \"FINAL-PTY-CONTEXT\"; exit 9 }'"]
            let burst = TerminalSession(host: nil, launch: burstLaunch, settings: AppSettings(), directory: model.workingDirectory)
            model.addSession(burst); burst.start()
            try await wait { burst.ended }
            let text = try String(contentsOf: burst.diagnosticURL!, encoding: .utf8)
            precondition(text.contains("FINAL-PTY-CONTEXT"), "Process exit overtook pending PTY output")
            model.closeAll()
        }
        print("PASS output bursts preserve the final PTY bytes before exit reporting")

        // Exercise EOF before process exit and a parent leaving a background child.
        // macOS may revoke the slave immediately, before the drain timeout is needed.
        for command in [
            "printf 'EARLY-EOF'; exec </dev/null >/dev/null 2>&1; sleep 0.3; exit 9",
            "trap '' HUP; sleep 4 & printf 'HELD-PTY'; exit 9"
        ] {
            var edgeLaunch = try launch(shell: nil)
            edgeLaunch.arguments = ["-c", command]
            let edge = TerminalSession(host: nil, launch: edgeLaunch, settings: AppSettings(), directory: model.workingDirectory)
            model.addSession(edge)
            let started = Date()
            edge.start()
            try await wait { edge.ended }
            let elapsed = Date().timeIntervalSince(started)
            precondition(elapsed < 3.5, "A background descendant must not hold the exit notification indefinitely")
            let data = try Data(contentsOf: edge.diagnosticURL!)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let context = try decoder.decode(TerminalDiagnostic.self, from: data)
            precondition(context.processExitCode == 9 && !context.terminalTail.isEmpty)
            model.closeAll()
            print("PASS PTY completion ordering with bounded descendant lifetime (\(elapsed)s)")
        }

        let retry = TerminalSession(host: Host(name: "offline", address: "127.0.0.1"),
                                    launch: try launch(shell: nil), settings: AppSettings(), directory: model.workingDirectory)
        retry.makeLaunch = { try launch(shell: nil) }
        model.addSession(retry)
        retry.start()
        for delay in [5, 10, 30, 60, 120] {
            try await wait { retry.ended }
            precondition(retry.reconnecting && retry.status.contains("Retrying in \(delay)s"))
            let old = retry.terminal
            retry.reconnect(manual: false)
            retry.processTerminated(source: old, exitCode: 0)
            precondition(model.sessions.contains { $0.id == retry.id }, "Stale process completion must not close the new session")
        }
        try await wait { retry.ended }
        precondition(!retry.reconnecting && retry.status.contains("Reconnect manually"))
        retry.reconnect()
        try await wait { retry.ended }
        precondition(retry.reconnecting && retry.status.contains("Retrying in 5s"))
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
