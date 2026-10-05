import AppKit
import SwiftUI
import BozhouCore

private final class LayoutProbeWindow: NSWindow {
    // Render large-window layouts even when the attached display is smaller.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Exercises real views and PTYs. Rendered views are not desktop screenshots.
@MainActor
enum NativeLayoutProbe {
    static func run(model: AppModel, names: [String]) throws {
        model.settings.autoReconnect = false
        let content = NSHostingView(rootView: RootView().environmentObject(model))
        let window = LayoutProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        window.orderFront(nil)
        defer { model.closeAll(); window.orderOut(nil) }
        let output = URL(fileURLWithPath: ".runtime/logs/ui-polish-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)); content.layoutSubtreeIfNeeded() }
        func wait(_ seconds: Double, until done: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard done() else { throw BozhouError.connection("Layout probe timed out") }
        }
        func capture(_ name: String) throws {
            settle()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        func check(_ passed: Bool, _ message: String) throws {
            guard passed else { throw BozhouError.invalid(message) }
        }
        func execute(_ session: TerminalSession, _ command: String) throws -> Interaction {
            let count = session.recent.count
            session.send(command, execute: true)
            try wait(15) { session.recent.count > count && session.recent.first?.command == command }
            let record = session.recent.first!
            try check(record.exitCode == 0, "Readonly command failed: \(session.title)")
            return record
        }
        for name in names {
            guard let host = model.hosts.first(where: { $0.name == name }) else { throw BozhouError.invalid("Unknown probe host: \(name)") }
            model.connect(host)
            guard let session = model.active else { throw BozhouError.connection(model.error ?? "No session") }
            try wait(45) { session.connected || session.ended }
            try check(session.connected, "\(name): \(session.status)")
            let result = try execute(session, "hostname")
            let saved = model.hosts.first { $0.id == host.id }?.systemProfile?.hostname
            try check(saved?.isEmpty == false && result.output.contains(saved!), "Hostname missing or differs from real command")
            print("PASS \(name): authenticated, hostname matches command and saved profile")
        }
        if names.isEmpty {
            for _ in 0..<4 {
                model.localTerminal()
                let session = model.active!
                try wait(10) { session.connected || session.ended }
                try check(session.connected, "Local shell did not start")
            }
        }
        let sessions = model.sessions
        try check(sessions.count >= 2, "At least two sessions required")
        // Settings must affect already open terminal objects and survive storage.
        model.settings.terminalBackgroundHex = nil
        model.settings.appearance = "light"
        model.saveSettings()
        try check(sessions.allSatisfy { TerminalAppearance.hex($0.terminal.nativeBackgroundColor) == "#F1F2F4" }, "Default is not light gray")
        for hex in ["#DEE7EF", "#18222E"] {
            model.settings.terminalBackgroundHex = hex
            model.saveSettings()
            try check(sessions.allSatisfy { TerminalAppearance.hex($0.terminal.nativeBackgroundColor) == hex }, "Open terminals did not update")
            try check(try model.store.loadSettings().terminalBackgroundHex == hex, "Color did not persist")
        }
        try check(TerminalAppearance.usesLightText(on: sessions[0].terminal.nativeBackgroundColor), "Dark background needs light text")
        for invalid in ["#fff", "#GGHHII", "0xFFFF", "FFFFFF00", ""] {
            try check(TerminalAppearance.color(hex: invalid) == nil, "Invalid color accepted")
        }
        try check(TerminalAppearance.hex(TerminalAppearance.color(hex: " abcdef ")!) == "#ABCDEF", "Color normalization failed")
        model.settings.terminalBackgroundHex = nil
        model.saveSettings()
        print("PASS default/custom colors, live application, persistence, normalization and contrast")
        let sizes: [(CGFloat, CGFloat)] = [(940, 580), (1100, 720), (1440, 900)]
        for (width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            model.activeSession = nil; model.splitSession = nil
            for page in Page.allCases {
                model.page = page
                settle()
                try check(abs(content.bounds.width - width) < 2 && abs(content.bounds.height - height) < 2, "\(page.rawValue) forces the window larger")
                if width == 940 || page == .settings { try capture("\(Int(width))-\(page.rawValue)") }
            }
            for session in sessions {
                model.activeSession = session.id
                settle()
                try check(session.terminal.window === window, "Switching session did not attach its terminal")
            }
            model.activeSession = sessions[0].id
            for vertical in [false, true] {
                model.splitVertical = vertical; model.splitSession = sessions[1].id
                settle()
                var rects: [NSRect] = []
                for session in sessions.prefix(2) {
                    let terminal = session.terminal
                    let rect = terminal.convert(terminal.bounds, to: content)
                    rects.append(rect)
                    try check(terminal.window === window, "Split pane detached")
                    try check(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Terminal extends beyond content")
                    let dims = terminal.getTerminal().getDims()
                    try check(dims.cols >= 40 && dims.rows >= 8, "Split terminal is too small: \(dims)")
                    let result = try execute(session, "stty size")
                    try check(result.output.contains("\(dims.rows) \(dims.cols)"), "PTY size did not match view")
                }
                try check(!rects[0].intersects(rects[1]), "Split terminal panes overlap")
                try capture("\(Int(width))-\(vertical ? "上下分屏" : "左右分屏")")
            }
            print("PASS \(Int(width))×\(Int(height)): all pages, \(sessions.count) session switches, both split directions and remote PTY sizes")
        }
        model.splitSession = nil; model.activeSession = nil; model.page = .hosts
        if let hostname = model.hosts.compactMap({ $0.systemProfile?.hostname }).first {
            model.search = hostname
            try check(!model.filteredHosts.isEmpty, "Hostname search failed")
            try capture("hostname-search")
            model.search = ""
            print("PASS hostname search")
        }
        try check(sessions.allSatisfy(\.connected), "A session disconnected during layout checks")
        print("PASS all sessions stayed connected during layout checks")
    }
}
