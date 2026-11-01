import AppKit
import SwiftUI
import BozhouCore

/// Exercise the real Window, menu shortcuts, native search highlights and tab layouts.
@main
struct NativeTitlebarProbe: App {
    @StateObject private var model: AppModel
    init() { _model = StateObject(wrappedValue: try! AppModel()) }
    var body: some Scene {
        Window("泊舟标题栏测试", id: "titlebar-probe") {
            RootView().environmentObject(model).onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Task { @MainActor in
                        do { try await run(); finish(0) }
                        catch { print("FAIL \(error.localizedDescription)"); finish(1) }
                    }
                }
            }
        }.defaultSize(width: 1100, height: 720)
            .windowStyle(.hiddenTitleBar).windowToolbarStyle(.unifiedCompact)
            .commands { FindCommands() }
    }
    @MainActor private func finish(_ status: Int32) -> Never {
        model.closeAll()
        if let path = ProcessInfo.processInfo.environment["BOZHOU_PROBE_STATUS"] {
            try? String(status).write(toFile: path, atomically: true, encoding: .utf8)
        }
        exit(status)
    }
    @MainActor private func run() async throws {
        setbuf(stdout, nil)
        guard let window = NSApp.windows.first(where: { $0.title == "泊舟标题栏测试" }),
              let frame = window.contentView?.superview else { throw BozhouError.invalid("Missing window") }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOZHOU_PROBE_RENDERS"] ?? ".runtime/logs/ui-polish-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1100, height: 720))
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(300))
            frame.layoutSubtreeIfNeeded()
        }
        func check(_ passed: Bool, _ message: String) throws {
            if !passed { throw BozhouError.invalid(message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func capture(_ name: String) async throws {
            try await settle()
            let visible = window.sheets.first?.contentView?.superview ?? frame
            if let bitmap = visible.bitmapImageRepForCachingDisplay(in: visible.bounds) {
                visible.cacheDisplay(in: visible.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
            print("PASS \(name): window \(window.frame.size), content \(window.contentLayoutRect.size), toolbar \(window.toolbar != nil)")
        }
        if ProcessInfo.processInfo.environment["BOZHOU_VERIFY_UPDATE_UI"] == "1" {
            model.page = .settings
            try await capture("maintenance-settings")
            for scroll in descendants(frame).compactMap({ $0 as? NSScrollView }) {
                if let document = scroll.documentView, document.bounds.height > scroll.contentSize.height {
                    document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height - scroll.contentSize.height : 0))
                }
            }
            try await capture("maintenance-data-and-update")
            model.updater.checkOnLaunch()
            let deadline = Date().addingTimeInterval(40)
            while model.updater.busy, Date() < deadline { try await settle() }
            try check(model.updater.checkedAt != nil && model.updater.release != nil,
                      "Startup release check failed: \(model.updater.status)")
            let checkedAt = model.updater.checkedAt
            model.updater.checkOnLaunch()
            try check(!model.updater.busy && model.updater.checkedAt == checkedAt,
                      "Startup check ran more than once")
            try check(model.updater.presented, "New release did not present the update sheet")
            try await capture("maintenance-update-startup")
            model.updater.presented = false
            try await settle()
            model.updater.check()
            try check(model.updater.presented, "Manual update check did not open the sheet")
            while model.updater.busy, Date() < deadline { try await settle() }
            try check(model.updater.checkedAt != checkedAt, "Manual check did not refresh")
            try await capture("maintenance-update-manual")
            model.updater.presented = false
            try await settle()
            print("PASS settings rendering, one startup check and manual update presentation")
        }
        let outputText = String(repeating: "context line\n", count: 200) + "Needle café 部署\nanother NEEDLE\n"
        let item = Interaction(hostName: "Fixture", sessionID: UUID(), shell: "zsh", command: "cat result", output: outputText)
        try model.store.save(item); try model.store.save(Pin(item))
        try model.saveIdentity(Identity(name: "Needle Key", privateKeyPath: "/tmp/fixture-key", fingerprint: "fixture", group: "Team/Production"))
        model.setIdentityGroupExpanded("Team", expanded: true)
        model.setIdentityGroupExpanded("Team/Production", expanded: true)
        try model.store.save(Snippet(name: "Needle Check", command: "printf needle"))
        model.log.write("Needle app event")
        try outputText.write(to: model.paths.logs.appendingPathComponent("fixture.ssh.log"), atomically: true, encoding: .utf8)
        try outputText.write(to: model.paths.knownHosts, atomically: true, encoding: .utf8)
        try model.reload()
        func find(_ query: String) async throws {
            try await settle()
            window.makeKeyAndOrderFront(nil)
            try await settle()
            if NSApp.isActive, NSApp.keyWindow === window {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
                try check(NSApp.mainMenu?.performKeyEquivalent(with: event) == true, "Command-F is missing or disabled")
            } else {
                // A locked desktop cannot grant foreground focus. Still test real editing/filtering.
                guard let field = descendants(frame).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.isEditable && ($0.placeholderString?.hasPrefix("Search") ?? false) }) else {
                    throw BozhouError.invalid("Search field not found")
                }
                window.makeFirstResponder(field)
                print("SKIP foreground Command-F: desktop unavailable; exercising native field editing")
            }
            try await settle()
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                for field in descendants(frame).compactMap({ $0 as? NSTextField }) {
                    print("FIELD id=\(field.identifier?.rawValue ?? "nil") ax=\(field.accessibilityIdentifier()) editable=\(field.isEditable) hidden=\(field.isHiddenOrHasHiddenAncestor) frame=\(field.frame)")
                }
                func dumpFind(_ menu: NSMenu) {
                    for item in menu.items {
                        if item.keyEquivalent == "f" { print("MENU \(item.title) enabled=\(item.isEnabled) action=\(String(describing: item.action))") }
                        if let submenu = item.submenu { dumpFind(submenu) }
                    }
                }
                if let menu = NSApp.mainMenu { dumpFind(menu) }
                try await capture("search-focus-failure")
                throw BozhouError.invalid("Command-F did not focus a search field: responder=\(String(describing: window.firstResponder)), key=\(String(describing: NSApp.keyWindow?.title)), active=\(NSApp.isActive), canKey=\(window.canBecomeKey)")
            }
            let changed = editor.string != query
            editor.selectAll(nil)
            editor.insertText(query, replacementRange: editor.selectedRange())
            try await settle()
            if changed {
                for output in descendants(frame).compactMap({ $0 as? NSTextView }) where !output.isFieldEditor {
                    let hit = (output.string as NSString).range(of: query, options: [.caseInsensitive])
                    if hit.location != NSNotFound {
                        try check(output.textStorage?.attribute(.backgroundColor, at: hit.location, effectiveRange: nil) == nil,
                                  "Search ran before the one-second debounce")
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(1100))
            try await settle()
        }
        for page in [Page.history, .pins, .logs, .identities, .snippets, .knownHosts] {
            model.page = page
            try await find("needle")
            if [.history, .pins, .logs, .knownHosts].contains(page) {
                let text = descendants(frame).compactMap { $0 as? NSTextView }
                    .first { !$0.isFieldEditor && $0.string.contains("NEEDLE") }
                try check(text != nil, "\(page): search did not reveal matching output")
                let hit = (text!.string as NSString).range(of: "Needle")
                try check(text!.textStorage?.attribute(.backgroundColor, at: hit.location, effectiveRange: nil) != nil,
                          "\(page): native output is missing a highlight")
                try check(text!.enclosingScrollView!.contentView.bounds.minY > 0, "\(page): deep hit was not scrolled into view")
            }
            try await capture("search-" + page.rawValue)
            print("PASS \(page.rawValue): native typing, filtering and search rendering")
        }
        model.page = .logs
        try await settle()
        if let segmented = descendants(frame).compactMap({ $0 as? NSSegmentedControl }).first {
            segmented.selectedSegment = 1
            segmented.sendAction(segmented.action, to: segmented.target)
            try await find("needle")
            try await capture("search-app-events")
        } else { throw BozhouError.invalid("Log type switch not found") }
        model.page = .hosts
        try await capture("toolbar-workspace")
        // Local cat PTYs with synthetic host metadata: no real server is contacted.
        for index in 0..<4 {
            var host = Host(name: "Production-AZA-C1-SP-\(index)", address: "127.0.0.1")
            host.systemProfile = SystemProfile(operatingSystem: "fixture", kernel: "", cpu: "", memory: "", hostname: "machine-long-hostname-99hm\(index)T")
            let directory = model.paths.sessions.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let launch = SSHLaunch(executable: "/bin/cat", arguments: [], environment: ["TERM": "xterm-256color"], directory: directory, token: UUID().uuidString)
            model.addSession(TerminalSession(host: host, launch: launch, settings: model.settings, directory: model.workingDirectory))
            try await settle()
        }
        let first = model.sessions[0]
        first.renameTab("Custom Production Terminal")
        try check(first.tabDisplayName.name == "Custom Production Terminal" && first.tabDisplayName.hostname == first.displayName.hostname,
                  "Renaming a tab changed its host identity")
        try await capture("toolbar-four-sessions")
        window.setContentSize(NSSize(width: 940, height: 580))
        try await capture("toolbar-four-sessions-940")
        let visible = Set((window.toolbar?.visibleItems ?? []).map {
            $0.itemIdentifier.rawValue.hasPrefix("tabs-") ? "tabs" : $0.itemIdentifier.rawValue
        })
        try check(["tabs", "sessions", "split", "tab-layout", "new"].allSatisfy { visible.contains($0) },
                  "Toolbar hid a tab strip or control in its overflow menu: \(visible)")
        for _ in 0..<4 { model.localTerminal(); try await settle() }
        try await capture("toolbar-eight-sessions-940")
        model.activeSession = nil
        try await capture("toolbar-workspace-eight-sessions")
        let terminal = first.terminal
        terminal.feed(text: "KEEP-TAB-HISTORY\r\n")
        model.activeSession = first.id
        for placement in [SessionTabPlacement.vertical, .horizontal, .vertical] {
            model.setTabPlacement(placement)
            try await settle()
            try check(first.terminal === terminal && terminal.window === window, "Changing tab layout replaced or detached the PTY")
            try check(try model.store.loadSettings().tabPlacement == placement, "Tab placement did not persist")
        }
        try await capture("toolbar-vertical-940")
        model.splitSession = model.sessions[1].id
        try await capture("toolbar-vertical-split-940")
        for session in model.sessions.prefix(2) {
            let rect = session.terminal.convert(session.terminal.bounds, to: frame)
            try check(frame.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Vertical tabs pushed a split terminal outside the window: \(rect), bounds \(frame.bounds)")
        }
        model.splitSession = nil
        model.activeSession = nil; model.page = .identities
        try await capture("key-folders-vertical-tabs")
        try check(try Store(url: model.paths.database).loadSettings().expandedIdentityGroups == ["Team", "Team/Production"],
                  "Search changed saved folder expansion")
        print("PASS tab names, persistent layout, split bounds, stable PTY attachment and key tree expansion")
    }
}
