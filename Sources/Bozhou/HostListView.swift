import AppKit
import SwiftUI
import BozhouCore

struct HostRow: Identifiable, Equatable {
    let id: String
    let folder: String?
    let host: Host?
    let depth: Int
}

/// Native selection is immediate; doubleAction does not delay the first click.
struct HostListView: NSViewRepresentable {
    var rows: [HostRow]
    var expanded: Set<String>
    @Binding var selection: String?
    var onMove: (MoveCommandDirection) -> Void
    var onOpen: (HostRow) -> Void
    var onToggle: (String) -> Void
    var onPreview: (Host) -> Void
    var menu: (HostRow) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = HostTableView()
        let column = NSTableColumn(identifier: .init("host"))
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openRow)
        table.onMove = { context.coordinator.parent.onMove($0) }
        table.onOpen = { context.coordinator.openRow() }
        table.onPreview = {
            let parent = context.coordinator.parent
            guard let index = context.coordinator.table?.selectedRow, parent.rows.indices.contains(index),
                  let host = parent.rows[index].host else { return }
            parent.onPreview(host)
        }
        table.rowMenu = { context.coordinator.parent.menu($0) }
        table.setAccessibilityLabel("主机列表")
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.rows != rows || coordinator.parent.expanded != expanded
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        table.rows = rows
        if changed || table.numberOfRows != rows.count { table.reloadData() }
        if let index = rows.firstIndex(where: { $0.id == selection }) {
            if table.selectedRow != index {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
            }
        } else { table.deselectAll(nil) }
        coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: HostListView
        weak var table: HostTableView?
        var updating = false
        init(_ parent: HostListView) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.rows[row].folder == nil ? 38 : 28
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = parent.rows.indices.contains(table.selectedRow) ? parent.rows[table.selectedRow].id : nil
        }
        @objc func openRow() {
            guard let table, parent.rows.indices.contains(table.selectedRow) else { return }
            parent.onOpen(parent.rows[table.selectedRow])
        }
        @objc func toggle(_ sender: NSButton) {
            guard parent.rows.indices.contains(sender.tag), let folder = parent.rows[sender.tag].folder else { return }
            table?.window?.makeFirstResponder(table)
            parent.selection = parent.rows[sender.tag].id
            parent.onToggle(folder)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = parent.rows[row]
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: item.folder == nil ? 38 : 28))
            let indent = CGFloat(item.depth * 16 + 6)
            let isFolder = item.folder != nil
            let detailWidth: CGFloat = isFolder ? 0 : 210
            if let folder = item.folder {
                let button = NSButton(image: NSImage(systemSymbolName: parent.expanded.contains(folder) ? "chevron.down" : "chevron.right",
                                                     accessibilityDescription: "展开或收起 \(folder)")!, target: self, action: #selector(toggle(_:)))
                button.isBordered = false; button.tag = row
                button.frame = NSRect(x: indent, y: 4, width: 18, height: 20)
                cell.addSubview(button)
            }
            let icon = NSImageView(frame: NSRect(x: indent + 22, y: isFolder ? 6 : 11, width: 16, height: 16))
            icon.image = NSImage(systemSymbolName: isFolder ? "folder.fill" : "server.rack", accessibilityDescription: nil)
            icon.contentTintColor = .controlAccentColor; cell.addSubview(icon)
            let title = HostNameTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: indent + 46, y: isFolder ? 6 : 19, width: max(80, tableView.bounds.width - indent - 70 - detailWidth), height: 17)
            title.autoresizingMask = [.width]
            title.hostName = item.host?.displayName ?? HostDisplayName(name: item.folder.map { ($0 as NSString).lastPathComponent } ?? "", hostname: nil)
            cell.textField = title; cell.addSubview(title)
            if let host = item.host {
                let subtitle = NSTextField(labelWithString: "\(host.username)@\(host.address):\(host.port)" + (host.favorite ? "  ★" : ""))
                subtitle.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
                subtitle.frame = NSRect(x: indent + 46, y: 3, width: max(80, tableView.bounds.width - indent - 70 - detailWidth), height: 14)
                subtitle.autoresizingMask = [.width]; cell.addSubview(subtitle)
                cell.toolTip = "\(host.name)\n主机名：\(host.systemProfile?.hostname ?? "下次登录后采集")\n\(host.username)@\(host.address):\(host.port)\n"
                    + (host.lastLoginAt.map { "上次登录 \($0.formatted())" } ?? "尚未登录")
                let details = [
                    host.systemProfile?.hostname ?? "主机名待采集",
                    host.lastLoginAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未登录"
                ]
                for (line, value) in details.enumerated() {
                    let label = NSTextField(labelWithString: value)
                    label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
                    label.alignment = .right; label.lineBreakMode = .byTruncatingTail
                    label.frame = NSRect(x: tableView.bounds.width - detailWidth - 10, y: line == 0 ? 20 : 3,
                                         width: detailWidth, height: 14)
                    label.autoresizingMask = [.minXMargin]; cell.addSubview(label)
                }
            }
            return cell
        }
    }
}

final class HostTableView: NSTableView {
    var rows: [HostRow] = []
    var onMove: ((MoveCommandDirection) -> Void)?
    var onOpen: (() -> Void)?
    var onPreview: (() -> Void)?
    var rowMenu: ((HostRow) -> NSMenu)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard rows.indices.contains(index) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if event.clickCount == 2 { sendAction(doubleAction, to: target) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onMove?(.left)
        case 124: onMove?(.right)
        case 125: onMove?(.down)
        case 126: onMove?(.up)
        case 36, 76: onOpen?()
        case 49 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty: onPreview?()
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard rows.indices.contains(index) else { return nil }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return rowMenu?(rows[index])
    }
}

final class HostMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
    static func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
        let handler = HostMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = handler; item.representedObject = handler; menu.addItem(item)
    }
}
