import AppKit
import SwiftUI
import BozhouCore

final class HostPreviewPanel: NSPanel {
    var onMove: ((MoveCommandDirection) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 49, 53: close(); return
            case 123: onMove?(.left); return
            case 124: onMove?(.right); return
            case 125: onMove?(.down); return
            case 126: onMove?(.up); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class HostPreviewController: ObservableObject {
    private(set) var panel: HostPreviewPanel?
    var isVisible: Bool { panel?.isVisible == true }
    func toggle(_ host: Host, hosts: [Host], onMove: @escaping (MoveCommandDirection) -> Void) {
        if isVisible { close(); return }
        let panel = panel ?? HostPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                                              styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                              backing: .buffered, defer: false)
        self.panel = panel
        panel.identifier = .init("BozhouHostPreview")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 420, height: 320)
        panel.onMove = onMove
        update(host, hosts: hosts)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
    func update(_ host: Host?, hosts: [Host]) {
        guard let panel else { return }
        guard let host else { close(); return }
        panel.title = host.displayName.full
        panel.contentView = NSHostingView(rootView: HostQuickLook(host: host, hosts: hosts))
    }
    func close() { panel?.close(); panel?.onMove = nil }
}

struct HostQuickLook: View {
    let host: Host
    let hosts: [Host]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(host.name, systemImage: "server.rack").font(.title2.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    field(L10n.tr("Hostname"), host.systemProfile?.hostname ?? L10n.tr("Not yet collected"))
                    field(L10n.tr("Address"), "\(host.address):\(host.port)")
                    field(L10n.tr("Username"), host.username)
                    field(L10n.tr("Folder"), host.folderPath)
                    field(L10n.tr("Authentication method"), host.authentication.title)
                    field(L10n.tr("Last login"), host.lastLoginAt.map { L10n.date($0) } ?? L10n.tr("Never logged in"))
                    if !host.tags.isEmpty { field(L10n.tr("Tags"), host.tags) }
                    if !host.jumpHosts.isEmpty {
                        field(L10n.tr("Jump host chain"), host.jumpHosts.map { id in
                            hosts.first { $0.id == id }?.displayName.full ?? L10n.tr("Deleted host")
                        }.joined(separator: " → "))
                    }
                    if let profile = host.systemProfile {
                        field(L10n.tr("Operating system"), profile.operatingSystem)
                        field(L10n.tr("Kernel & architecture"), profile.kernel)
                        field("CPU", profile.cpu)
                        field(L10n.tr("Memory"), profile.memory)
                    }
                    if !host.notes.isEmpty { field(L10n.tr("Notes"), host.notes) }
                }.textSelection(.enabled)
                Text(L10n.tr("Space / Esc Close · ↑↓ Switch host")).font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Text(value.isEmpty ? "—" : value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }
}
