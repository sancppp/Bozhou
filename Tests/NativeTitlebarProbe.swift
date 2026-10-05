import AppKit
import SwiftUI
import BozhouCore

/// Render the actual SwiftUI Window/toolbar, including overflow at narrow sizes.
@main
struct NativeTitlebarProbe: App {
    @StateObject private var model: AppModel
    init() { _model = StateObject(wrappedValue: try! AppModel()) }
    var body: some Scene {
        Window("泊舟标题栏测试", id: "titlebar-probe") {
            RootView().environmentObject(model).onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    do { try run(); model.closeAll(); exit(0) }
                    catch { print("FAIL \(error.localizedDescription)"); model.closeAll(); exit(1) }
                }
            }
        }.defaultSize(width: 1100, height: 720)
            .windowStyle(.hiddenTitleBar).windowToolbarStyle(.unifiedCompact)
    }
    @MainActor private func run() throws {
        setbuf(stdout, nil)
        guard let window = NSApp.windows.first(where: { $0.title == "泊舟标题栏测试" }),
              let frame = window.contentView?.superview else { throw BozhouError.invalid("Missing window") }
        let output = URL(fileURLWithPath: ".runtime/logs/ui-polish-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)); frame.layoutSubtreeIfNeeded() }
        func capture(_ name: String) throws {
            settle()
            if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
            print("PASS \(name): window \(window.frame.size), content \(window.contentLayoutRect.size), toolbar \(window.toolbar != nil)")
        }
        try capture("toolbar-workspace")
        for _ in 0..<4 { model.localTerminal(); settle() }
        try capture("toolbar-four-sessions")
        window.setContentSize(NSSize(width: 940, height: 580))
        try capture("toolbar-four-sessions-940")
        for _ in 0..<4 { model.localTerminal(); settle() }
        try capture("toolbar-eight-sessions-940")
        model.activeSession = nil
        try capture("toolbar-workspace-eight-sessions")
    }
}
