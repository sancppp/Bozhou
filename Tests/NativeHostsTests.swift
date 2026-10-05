import AppKit
import SwiftUI
import BozhouCore

@main
struct NativeHostsTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = try AppModel()
        if let index = CommandLine.arguments.firstIndex(of: "--layout") {
            try NativeLayoutProbe.run(model: model, names: Array(CommandLine.arguments.dropFirst(index + 1)))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--live-terminal") {
            try NativeLiveTerminalProbe.run(model: model, names: Array(CommandLine.arguments.dropFirst(index + 1)))
            return
        }
        for path in ["NAT", "NAT/成都", "NAT/成都/azc"] { model.createFolder(path) }
        try model.saveHost(Host(name: "主 SP-1", address: "127.0.0.1", group: "NAT/成都/azc"))
        try model.saveHost(Host(name: "主 SP-2", address: "127.0.0.2", group: "NAT/成都/azc"))
        let content = NSHostingView(rootView: RootView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let result = view as? T { return result }
            for child in view.subviews { if let result = find(type, in: child) { return result } }
            return nil
        }
        settle()
        let table = find(HostTableView.self, in: content)!
        precondition(table.numberOfRows == 1)
        window.makeFirstResponder(table)
        func key(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            window.sendEvent(event); settle()
        }
        key(125)
        precondition(table.selectedRow == 0)
        key(124)
        precondition(table.numberOfRows == 2)
        key(124)
        precondition(table.selectedRow == 1)
        key(124); key(124); key(124)
        precondition(table.numberOfRows == 5)
        key(125)
        precondition(table.rows[table.selectedRow].host?.name == "主 SP-1")
        key(125)
        precondition(table.rows[table.selectedRow].host?.name == "主 SP-2")
        key(126)
        precondition(table.rows[table.selectedRow].host?.name == "主 SP-1")
        key(123)
        precondition(table.rows[table.selectedRow].folder == "NAT/成都/azc")
        key(123)
        precondition(table.numberOfRows == 3)
        key(124)
        precondition(table.numberOfRows == 5)
        print("PASS native window responder: ↑↓ choose hosts, → expand/enter, ← parent/collapse")
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".runtime/logs/phase4-hosts-render.png"))
        }

        // Dispatch directly to the native table; CLI test windows cannot reliably become
        // the system key window. This tests AppKit selection without OS event injection.
        func click(row: Int, count: Int) {
            let rect = table.rect(ofRow: row)
            let location = table.convert(NSPoint(x: 150, y: rect.midY), to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: count, pressure: 0)!
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                         timestamp: up.timestamp, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
            app.postEvent(up, atStart: true)
            table.mouseDown(with: down)
        }
        let start = ProcessInfo.processInfo.systemUptime
        click(row: 4, count: 1)
        let clickMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        settle()
        precondition(table.selectedRow == 4, "Selection must update before waiting for a double click")
        precondition(clickMS < 200, "Single click must not wait for the system double-click interval")
        settle()
        precondition(window.firstResponder === table)
        print("PASS native single click selects synchronously: \(Int(clickMS)) ms")
        click(row: 1, count: 2)
        settle()
        precondition(model.selectedGroup == "NAT/成都")
        precondition(table.rows.first?.folder == "NAT/成都/azc")
        key(36)
        // No current selection after navigating. Pick the child folder, then Return.
        key(125); key(36)
        precondition(model.selectedGroup == "NAT/成都/azc")
        print("PASS native double click and Return open folders")

        model.selectedGroup = ""
        settle()
        key(125)
        key(124)
        key(124)
        key(124)
        key(124)
        key(124)
        settle()
        content.layoutSubtreeIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: ".runtime/logs/phase4-hosts-render.png"))
            }
        }
        print("PASS compact layout: folder 28 pt, host 38 pt, sidebar 160 pt; rendered view saved")
        window.orderOut(nil)
    }
}
