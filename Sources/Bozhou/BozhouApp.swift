import SwiftUI
import BozhouCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.sessions.contains(where: { !$0.ended }) else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "退出泊舟？"
        alert.informativeText = "正在进行的终端连接将断开。"
        alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model?.closeAll() }
}

@main
struct BozhouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        do {
            let instance = try AppModel()
            _model = StateObject(wrappedValue: instance)
        }
        catch {
            let alert = NSAlert(); alert.messageText = "泊舟无法启动"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "退出"); alert.runModal(); exit(1)
        }
    }
    var body: some Scene {
        Window("泊舟", id: "main") {
            RootView().environmentObject(model).onAppear { delegate.model = model }
        }.defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建主机") { model.editorHost = Host() }.keyboardShortcut("n")
                Button("新建本地终端") { model.localTerminal() }.keyboardShortcut("t")
                Button("搜索主机") {
                    model.activeSession = nil; model.page = .hosts
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .init("BozhouFocusSearch"), object: nil) }
                }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("清除终端屏幕") { model.commandSession?.terminal.clearScreen() }
                    .keyboardShortcut("k").disabled(model.activeSession == nil)
            }
            CommandMenu("连接") {
                Button("重新连接") { model.commandSession?.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.commandSession?.host == nil || model.commandSession?.ended != true)
                Button("关闭当前会话") { if let id = model.commandSession?.id { model.closeSession(id) } }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.activeSession == nil)
                Button("收藏最近交互") { if let session = model.commandSession { model.pin(session.recent.first ?? session.snapshot()) } }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.activeSession == nil)
                Divider()
                ForEach(model.hosts.filter(\.favorite)) { host in Button(host.name) { model.connect(host) } }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.activeSession = nil; model.page = .settings }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button("泊舟使用指南") {
                    if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) }
                }
            }
        }
        MenuBarExtra("泊舟", systemImage: "sailboat") {
            StatusMenu().environmentObject(model)
        }
    }
}

struct StatusMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开泊舟") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Text("\(model.sessions.filter { !$0.ended }.count) 个活动会话")
        Divider()
        ForEach(model.hosts.filter(\.favorite)) { host in
            Button(host.name) { openWindow(id: "main"); model.connect(host); NSApp.activate(ignoringOtherApps: true) }
        }
        Divider()
        Button("退出泊舟") { NSApp.terminate(nil) }
    }
}
