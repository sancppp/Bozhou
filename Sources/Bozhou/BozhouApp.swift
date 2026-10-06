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
        let alert = NSAlert(); alert.messageText = L10n.tr("Quit Bozhou?")
        alert.informativeText = L10n.tr("Active terminal connections will be disconnected.")
        alert.addButton(withTitle: L10n.tr("Quit")); alert.addButton(withTitle: L10n.tr("Cancel"))
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
            let alert = NSAlert(); alert.messageText = L10n.tr("Bozhou Could Not Start"); alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.tr("Quit")); alert.runModal(); exit(1)
        }
    }
    var body: some Scene {
        Window(L10n.tr("Bozhou"), id: "main") {
            RootView().environmentObject(model).environment(\.locale, L10n.language.locale)
                .onAppear { delegate.model = model }
        }.defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("New Host")) { model.editorHost = Host() }.keyboardShortcut("n")
                Button(L10n.tr("New Local Terminal")) { model.localTerminal() }.keyboardShortcut("t")
                Button(L10n.tr("Search Hosts")) {
                    model.activeSession = nil; model.page = .hosts
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .init("BozhouFocusSearch"), object: nil) }
                }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button(L10n.tr("Clear Terminal Screen")) { model.commandSession?.terminal.clearScreen() }
                    .keyboardShortcut("k").disabled(model.activeSession == nil)
            }
            CommandGroup(after: .toolbar) {
                Button(L10n.tr("Increase Terminal Font Size")) { model.commandSession?.changeFontSize(by: 1) }
                    .keyboardShortcut("=").disabled(model.activeSession == nil)
                Button(L10n.tr("Decrease Terminal Font Size")) { model.commandSession?.changeFontSize(by: -1) }
                    .keyboardShortcut("-").disabled(model.activeSession == nil)
            }
            CommandMenu(L10n.tr("Connections")) {
                Button(L10n.tr("Reconnect")) { model.commandSession?.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.commandSession?.host == nil || model.commandSession?.ended != true)
                Button(L10n.tr("Close Current Session")) { if let id = model.commandSession?.id { model.closeSession(id) } }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.activeSession == nil)
                Button(L10n.tr("Pin Latest Interaction")) { if let session = model.commandSession { model.pin(session.recent.first ?? session.snapshot()) } }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.activeSession == nil)
                Divider()
                ForEach(model.hosts.filter(\.favorite)) { host in Button(host.displayName.full) { model.connect(host) } }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("Settings…")) { model.activeSession = nil; model.page = .settings }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .appInfo) {
                Button(L10n.tr("About Bozhou")) { showAboutPanel() }
            }
            CommandGroup(replacing: .help) {
                Button(L10n.tr("Bozhou Project Homepage")) { NSWorkspace.shared.open(AppLinks.repository) }
            }
        }
        MenuBarExtra(L10n.tr("Bozhou"), systemImage: "sailboat") {
            StatusMenu().environmentObject(model).environment(\.locale, L10n.language.locale)
        }
    }
    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: AppLinks.repositoryDisplayName,
            attributes: [
                .link: AppLinks.repository,
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StatusMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button(L10n.tr("Open Bozhou")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Text(L10n.tr("Active sessions: \(model.sessions.filter { !$0.ended }.count)"))
        Divider()
        ForEach(model.hosts.filter(\.favorite)) { host in
            Button(host.displayName.full) { openWindow(id: "main"); model.connect(host); NSApp.activate(ignoringOtherApps: true) }
        }
        Divider()
        Button(L10n.tr("Quit Bozhou")) { NSApp.terminate(nil) }
    }
}
