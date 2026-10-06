import SwiftUI
import BozhouCore

struct HostsPage: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hostsListLayout") private var listLayout = true
    @State private var selection: String?
    @State private var deleting: Host?
    @State private var folderPrompt = false
    @State private var folderPath = ""
    @State private var renaming: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool
    @StateObject private var preview = HostPreviewController()

    // Search reveals matches temporarily without changing the saved folder state.
    private var expanded: Set<String> {
        model.search.isEmpty ? model.settings.expandedHostGroups : Set(model.groups)
    }
    private var rows: [HostRow] {
        var result: [HostRow] = []
        let groups = model.groups
        let hosts = model.filteredHosts
        let expanded = expanded
        func visit(_ parent: String, depth: Int) {
            let children = groups.filter { path in
                HostTree.parent(path) == parent && (model.search.isEmpty || hosts.contains(where: { host in HostTree.contains(host.group, in: path) }))
            }.sorted { a, b in
                if model.hostSort == .created {
                    let x = model.folders.first { $0.path == a }?.createdAt ?? .distantPast
                    let y = model.folders.first { $0.path == b }?.createdAt ?? .distantPast
                    if x != y { return model.sortAscending ? x < y : x > y }
                }
                return model.sortAscending ? a.localizedStandardCompare(b) == .orderedAscending : a.localizedStandardCompare(b) == .orderedDescending
            }
            for path in children {
                result.append(HostRow(id: "f:" + path, folder: path, host: nil, depth: depth))
                if expanded.contains(path) { visit(path, depth: depth + 1) }
            }
            for host in hosts where host.group == parent {
                result.append(HostRow(id: "h:" + host.id.uuidString, folder: nil, host: host, depth: depth))
            }
        }
        visit(model.selectedGroup, depth: 0)
        return result
    }
    private var selectedRow: HostRow? { rows.first { $0.id == selection } }
    private var selectedHost: Host? { model.hosts.first { "h:" + $0.id.uuidString == selection } }
    private var currentFolders: [String] { model.groups.filter { HostTree.parent($0) == model.selectedGroup }.sorted() }
    private var gridHosts: [Host] { model.filteredHosts.filter { !model.search.isEmpty || $0.group == model.selectedGroup } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("Search name, hostname, address, username or tags"), text: $model.search).textFieldStyle(.plain).focused($searchFocused)
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(model.selectedGroup.isEmpty ? L10n.tr("All Hosts") : (model.selectedGroup as NSString).lastPathComponent)
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.tr("Hosts: \(model.filteredHosts.count)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { listLayout.toggle() } label: { Image(systemName: listLayout ? "square.grid.2x2" : "list.bullet") }.help(L10n.tr("Switch layout"))
                Menu {
                    Picker(L10n.tr("Sort by"), selection: $model.hostSort) { ForEach(HostSort.allCases) { Text($0.title).tag($0) } }
                    Toggle(L10n.tr("Ascending"), isOn: $model.sortAscending)
                } label: { Label(L10n.tr("Sort"), systemImage: "arrow.up.arrow.down") }.fixedSize()
                Button { newFolder() } label: { Image(systemName: "folder.badge.plus") }.help(L10n.tr("New Folder"))
                Button(L10n.tr("Local Terminal")) { model.localTerminal() }
                Button(L10n.tr("New Host")) { model.editorHost = Host(group: model.selectedGroup) }.buttonStyle(.borderedProminent)
            }
            HStack(spacing: 6) {
                Button(L10n.tr("All Hosts")) { model.selectedGroup = ""; selection = nil }.buttonStyle(.link)
                ForEach(HostTree.ancestors(model.selectedGroup), id: \.self) { path in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button((path as NSString).lastPathComponent) { model.selectedGroup = path; selection = nil }.buttonStyle(.link)
                }
                Spacer()
            }.font(.caption)
            if listLayout {
                list
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        if model.search.isEmpty {
                            ForEach(currentFolders, id: \.self) { path in
                                Button { model.selectedGroup = path } label: {
                                    Label((path as NSString).lastPathComponent, systemImage: "folder.fill")
                                        .font(.headline).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                                        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                                }.buttonStyle(.plain).contextMenu { folderMenu(path) }
                            }
                        }
                        ForEach(gridHosts) { host in hostCard(host) }
                    }
                }.focusable().focused($gridFocused)
                    .onKeyPress(.space) {
                        guard let host = selectedHost else { return .ignored }
                        showPreview(host); return .handled
                    }
                    .onMoveCommand(perform: move)
            }
            HStack {
                Text(listLayout ? L10n.tr("↑↓ Select · → Expand · ← Collapse · Space Preview · Return Connect · Double-click Open") : L10n.tr("Click Select · Space Preview · Click Connect to open a terminal"))
                Spacer()
                if let host = selectedHost {
                    Button(L10n.tr("Details")) { model.editorHost = host }
                    Button("SFTP") { model.sftpHost = host }
                    Button(L10n.tr("Connect")) { model.connect(host) }
                }
            }.font(.caption).foregroundStyle(.secondary).frame(height: 28)
        }.padding(14)
            .alert(L10n.tr("Delete Host?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("Delete"), role: .destructive) { if let deleting { model.deleteHost(deleting) }; deleting = nil }
            } message: { Text(L10n.tr("Only the connection configuration will be deleted. Server files will remain.")) }
            .alert(renaming == nil ? L10n.tr("New Folder") : L10n.tr("Rename or Move Folder"), isPresented: $folderPrompt) {
                TextField(L10n.tr("Full path, e.g. Production/US East"), text: $folderPath)
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("Save")) {
                    if let renaming { model.renameFolder(renaming, to: folderPath) }
                    else { model.createFolder(folderPath) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("BozhouFocusSearch"))) { _ in searchFocused = true }
            .onChange(of: selection) { _, _ in if preview.isVisible { preview.update(selectedHost, hosts: model.hosts) } }
            .onChange(of: model.hosts) { _, _ in if preview.isVisible { preview.update(selectedHost, hosts: model.hosts) } }
            .onChange(of: model.selectedGroup) { _, _ in preview.close() }
            .onChange(of: model.search) { _, _ in preview.close() }
            .onChange(of: listLayout) { _, _ in preview.close() }
            .onDisappear { preview.close() }
    }

    private var list: some View {
        HostListView(rows: rows, expanded: expanded,
                     selection: $selection, onMove: move, onOpen: open, onToggle: toggle, onPreview: showPreview, menu: nativeMenu)
            .overlay {
                if rows.isEmpty { Text(L10n.tr("This folder is empty. Add a host or folder.")).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
    }
    private func nativeMenu(_ row: HostRow) -> NSMenu {
        let menu = NSMenu()
        if let path = row.folder {
            HostMenuAction.add(L10n.tr("Open Folder"), to: menu) { model.selectedGroup = path; selection = nil }
            HostMenuAction.add(L10n.tr("New Subfolder"), to: menu) { renaming = nil; folderPath = path + "/"; folderPrompt = true }
            HostMenuAction.add(L10n.tr("New Host Here"), to: menu) { model.editorHost = Host(group: path) }
            HostMenuAction.add(L10n.tr("Rename / Move"), to: menu) { renaming = path; folderPath = path; folderPrompt = true }
            HostMenuAction.add(L10n.tr("Delete Empty Folder"), to: menu) { model.deleteFolder(path) }
        }
        if let host = row.host {
            HostMenuAction.add(L10n.tr("Quick Look"), to: menu) { showPreview(host) }
            HostMenuAction.add(L10n.tr("Connect"), to: menu) { model.connect(host) }
            HostMenuAction.add("SFTP", to: menu) { model.sftpHost = host }
            HostMenuAction.add(L10n.tr("Details / Edit"), to: menu) { model.editorHost = host }
            let moveMenu = NSMenu()
            for path in [""] + model.groups {
                HostMenuAction.add(path.isEmpty ? L10n.tr("All Hosts") : path, to: moveMenu) {
                    var copy = host; copy.group = path; model.perform { try model.saveHost(copy) }
                }
            }
            let moveItem = NSMenuItem(title: L10n.tr("Move to Folder"), action: nil, keyEquivalent: "")
            moveItem.submenu = moveMenu; menu.addItem(moveItem)
            HostMenuAction.add(L10n.tr("Duplicate Configuration"), to: menu) {
                var copy = host; copy.id = UUID(); copy.name += L10n.tr(" copy"); copy.createdAt = Date()
                copy.lastLoginAt = nil; copy.systemProfile = nil; model.editorHost = copy
            }
            HostMenuAction.add(L10n.tr("Delete"), to: menu) { deleting = host }
        }
        return menu
    }
    private func move(_ direction: MoveCommandDirection) {
        if !listLayout {
            let hosts = gridHosts
            guard !hosts.isEmpty else { return }
            let index = hosts.firstIndex { $0.id == selectedHost?.id } ?? 0
            let next = direction == .down || direction == .right ? min(index + 1, hosts.count - 1) : max(0, index - 1)
            selection = "h:" + hosts[next].id.uuidString
            return
        }
        let all = rows
        guard !all.isEmpty else { return }
        guard let index = all.firstIndex(where: { $0.id == selection }) else { selection = all.first?.id; return }
        let row = all[index]
        switch direction {
        case .down: selection = all[min(index + 1, all.count - 1)].id
        case .up: selection = all[max(0, index - 1)].id
        case .right:
            if let folder = row.folder {
                if expanded.contains(folder), index + 1 < all.count, all[index + 1].depth > row.depth { selection = all[index + 1].id }
                else if model.search.isEmpty { model.setHostGroupExpanded(folder, expanded: true) }
            }
        case .left:
            if model.search.isEmpty, let folder = row.folder, expanded.contains(folder) {
                model.setHostGroupExpanded(folder, expanded: false)
            }
            else {
                let parent = row.folder.map(HostTree.parent) ?? row.host?.group ?? ""
                if all.contains(where: { $0.id == "f:" + parent }) { selection = "f:" + parent }
            }
        default: break
        }
    }
    private func toggle(_ path: String) {
        guard model.search.isEmpty else { return }
        model.setHostGroupExpanded(path, expanded: !expanded.contains(path))
    }
    private func showPreview(_ host: Host) { preview.toggle(host, hosts: model.hosts, onMove: move) }
    private func open(_ row: HostRow) {
        if let host = row.host { model.connect(host) }
        if let folder = row.folder { model.selectedGroup = folder; selection = nil }
    }
    private func newFolder() { renaming = nil; folderPath = model.selectedGroup.isEmpty ? "" : model.selectedGroup + "/"; folderPrompt = true }
    @ViewBuilder private func folderMenu(_ path: String) -> some View {
        Button(L10n.tr("Open Folder")) { model.selectedGroup = path; selection = nil }
        Button(L10n.tr("New Subfolder")) { renaming = nil; folderPath = path + "/"; folderPrompt = true }
        Button(L10n.tr("New Host Here")) { model.editorHost = Host(group: path) }
        Button(L10n.tr("Rename / Move")) { renaming = path; folderPath = path; folderPrompt = true }
        Button(L10n.tr("Delete Empty Folder"), role: .destructive) { model.deleteFolder(path) }
    }
    @ViewBuilder private func hostMenu(_ host: Host) -> some View {
        Button(L10n.tr("Quick Look")) { selection = "h:" + host.id.uuidString; showPreview(host) }
        Button(L10n.tr("Connect")) { model.connect(host) }
        Button("SFTP") { model.sftpHost = host }
        Button(L10n.tr("Details / Edit")) { model.editorHost = host }
        Menu(L10n.tr("Move to Folder")) {
            ForEach([""] + model.groups, id: \.self) { path in
                Button(path.isEmpty ? L10n.tr("All Hosts") : path) { var copy = host; copy.group = path; model.perform { try model.saveHost(copy) } }
            }
        }
        Button(L10n.tr("Duplicate Configuration")) {
            var copy = host; copy.id = UUID(); copy.name += L10n.tr(" copy"); copy.createdAt = Date()
            copy.lastLoginAt = nil; copy.systemProfile = nil; model.editorHost = copy
        }
        Button(L10n.tr("Delete"), role: .destructive) { deleting = host }
    }
    private func hostCard(_ host: Host) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "server.rack"); HostNameLabel(host.displayName) }.font(.headline).foregroundStyle(sea)
            Text(host.systemProfile?.hostname ?? L10n.tr("Hostname not yet collected")).font(.system(size: 11, design: .monospaced))
                .lineLimit(1).help(host.systemProfile?.hostname ?? L10n.tr("Collected at next login"))
            Text("\(host.username)@\(host.address)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Text(host.lastLoginAt.map { L10n.tr("Last login: \(L10n.date($0, abbreviated: true))") } ?? L10n.tr("Never logged in")).font(.caption2).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(L10n.tr("Details")) { model.editorHost = host }
                Button("SFTP") { model.sftpHost = host }
                Spacer()
                Button(L10n.tr("Connect")) { model.connect(host) }
            }.controlSize(.small)
        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(selectedHost?.id == host.id ? sea : .clear, lineWidth: 2) }
            .contentShape(Rectangle())
            .onTapGesture { selection = "h:" + host.id.uuidString; gridFocused = true }
            .contextMenu { hostMenu(host) }
    }
}
