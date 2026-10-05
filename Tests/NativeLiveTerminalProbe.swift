import AppKit
import SwiftUI
import BozhouCore

@MainActor
enum NativeLiveTerminalProbe {
    static func run(model: AppModel, names: [String]) throws {
        model.settings.autoReconnect = false
        let content = NSHostingView(rootView: RootView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content; window.orderFront(nil)
        defer { model.closeAll(); window.orderOut(nil) }
        func wait(_ seconds: Double, until done: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard done() else { throw BozhouError.connection("Native terminal probe timed out") }
        }
        for name in names {
            guard let host = model.hosts.first(where: { $0.name == name }) else { throw BozhouError.invalid("Unknown probe host") }
            model.connect(host)
            guard let session = model.active else { throw BozhouError.connection(model.error ?? "No terminal") }
            try wait(40) { session.connected || session.ended }
            guard session.connected else { throw BozhouError.connection("\(name): \(session.status)") }
            guard let current = model.hosts.first(where: { $0.id == host.id }),
                  current.lastLoginAt != nil, current.systemProfile?.kernel.contains("Linux") == true else {
                throw BozhouError.connection("System metadata was not saved")
            }
            let command = "printf 'phase4-terminal-probe\\n'; id -un; uname -s"
            session.send(command, execute: true)
            try wait(15) { session.recent.contains { $0.command == command && $0.exitCode == 0 } }
            let record = session.recent.first { $0.command == command }!
            guard record.output.contains(host.username), record.output.contains("Linux") else {
                throw BozhouError.connection("Unexpected readonly terminal response")
            }
            print("PASS \(name): native PTY ready, \(host.username), Linux, readonly command exit 0, login metadata persisted")
            session.send("exit", execute: true)
            try wait(10) { session.ended }
            model.closeSession(session.id)
        }
    }
}
