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
    private var currentFolders: [String] { model.groups.filter { HostTree.parent($0) == model.selectedGroup }.sorted() }
    private var gridHosts: [Host] { model.filteredHosts.filter { !model.search.isEmpty || $0.group == model.selectedGroup } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、主机名、地址、用户名或标签", text: $model.search).textFieldStyle(.plain).focused($searchFocused)
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(model.selectedGroup.isEmpty ? "所有主机" : (model.selectedGroup as NSString).lastPathComponent)
                    .font(.system(size: 18, weight: .semibold))
                Text("\(model.filteredHosts.count) 台").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { listLayout.toggle() } label: { Image(systemName: listLayout ? "square.grid.2x2" : "list.bullet") }.help("切换布局")
                Menu {
                    Picker("排序依据", selection: $model.hostSort) { ForEach(HostSort.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("升序", isOn: $model.sortAscending)
                } label: { Label("排序", systemImage: "arrow.up.arrow.down") }.fixedSize()
                Button { newFolder() } label: { Image(systemName: "folder.badge.plus") }.help("新建文件夹")
                Button("本地终端") { model.localTerminal() }
                Button("新建主机") { model.editorHost = Host(group: model.selectedGroup) }.buttonStyle(.borderedProminent)
            }
            HStack(spacing: 6) {
                Button("所有主机") { model.selectedGroup = ""; selection = nil }.buttonStyle(.link)
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
                }
            }
            HStack {
                Text(listLayout ? "↑↓ 选择 · → 展开 · ← 收起 · Return 连接 · 双击打开" : "点击文件夹进入 · 点击连接打开终端")
                Spacer()
                if let host = selectedRow?.host {
                    Button("详情") { model.editorHost = host }
                    Button("SFTP") { model.sftpHost = host }
                    Button("连接") { model.connect(host) }
                }
            }.font(.caption).foregroundStyle(.secondary).frame(height: 28)
        }.padding(14)
            .alert("删除主机？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { if let deleting { model.deleteHost(deleting) }; deleting = nil }
            } message: { Text("仅删除连接配置，不影响服务器文件。") }
            .alert(renaming == nil ? "新建文件夹" : "重命名或移动文件夹", isPresented: $folderPrompt) {
                TextField("完整路径，例如 生产环境/华北", text: $folderPath)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if let renaming { model.renameFolder(renaming, to: folderPath) }
                    else { model.createFolder(folderPath) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("BozhouFocusSearch"))) { _ in searchFocused = true }
    }

    private var list: some View {
        HostListView(rows: rows, expanded: expanded,
                     selection: $selection, onMove: move, onOpen: open, onToggle: toggle, menu: nativeMenu)
            .overlay {
                if rows.isEmpty { Text("此文件夹为空，可新建主机或文件夹").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
    }
    private func nativeMenu(_ row: HostRow) -> NSMenu {
        let menu = NSMenu()
        if let path = row.folder {
            HostMenuAction.add("打开文件夹", to: menu) { model.selectedGroup = path; selection = nil }
            HostMenuAction.add("新建子文件夹", to: menu) { renaming = nil; folderPath = path + "/"; folderPrompt = true }
            HostMenuAction.add("在此新建主机", to: menu) { model.editorHost = Host(group: path) }
            HostMenuAction.add("重命名 / 移动", to: menu) { renaming = path; folderPath = path; folderPrompt = true }
            HostMenuAction.add("删除空文件夹", to: menu) { model.deleteFolder(path) }
        }
        if let host = row.host {
            HostMenuAction.add("连接", to: menu) { model.connect(host) }
            HostMenuAction.add("SFTP", to: menu) { model.sftpHost = host }
            HostMenuAction.add("详情 / 编辑", to: menu) { model.editorHost = host }
            let moveMenu = NSMenu()
            for path in [""] + model.groups {
                HostMenuAction.add(path.isEmpty ? "所有主机" : path, to: moveMenu) {
                    var copy = host; copy.group = path; model.perform { try model.saveHost(copy) }
                }
            }
            let moveItem = NSMenuItem(title: "移至文件夹", action: nil, keyEquivalent: "")
            moveItem.submenu = moveMenu; menu.addItem(moveItem)
            HostMenuAction.add("复制配置", to: menu) {
                var copy = host; copy.id = UUID(); copy.name += " 副本"; copy.createdAt = Date()
                copy.lastLoginAt = nil; copy.systemProfile = nil; model.editorHost = copy
            }
            HostMenuAction.add("删除", to: menu) { deleting = host }
        }
        return menu
    }
    private func move(_ direction: MoveCommandDirection) {
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
    private func open(_ row: HostRow) {
        if let host = row.host { model.connect(host) }
        if let folder = row.folder { model.selectedGroup = folder; selection = nil }
    }
    private func newFolder() { renaming = nil; folderPath = model.selectedGroup.isEmpty ? "" : model.selectedGroup + "/"; folderPrompt = true }
    @ViewBuilder private func folderMenu(_ path: String) -> some View {
        Button("打开文件夹") { model.selectedGroup = path; selection = nil }
        Button("新建子文件夹") { renaming = nil; folderPath = path + "/"; folderPrompt = true }
        Button("在此新建主机") { model.editorHost = Host(group: path) }
        Button("重命名 / 移动") { renaming = path; folderPath = path; folderPrompt = true }
        Button("删除空文件夹", role: .destructive) { model.deleteFolder(path) }
    }
    @ViewBuilder private func hostMenu(_ host: Host) -> some View {
        Button("连接") { model.connect(host) }
        Button("SFTP") { model.sftpHost = host }
        Button("详情 / 编辑") { model.editorHost = host }
        Menu("移至文件夹") {
            ForEach([""] + model.groups, id: \.self) { path in
                Button(path.isEmpty ? "所有主机" : path) { var copy = host; copy.group = path; model.perform { try model.saveHost(copy) } }
            }
        }
        Button("复制配置") {
            var copy = host; copy.id = UUID(); copy.name += " 副本"; copy.createdAt = Date()
            copy.lastLoginAt = nil; copy.systemProfile = nil; model.editorHost = copy
        }
        Button("删除", role: .destructive) { deleting = host }
    }
    private func hostCard(_ host: Host) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(host.name, systemImage: "server.rack").font(.headline).foregroundStyle(sea).lineLimit(1).help(host.name)
            Text(host.systemProfile?.hostname ?? "主机名待采集").font(.system(size: 11, design: .monospaced))
                .lineLimit(1).help(host.systemProfile?.hostname ?? "下次登录后采集")
            Text("\(host.username)@\(host.address)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Text(host.lastLoginAt.map { "上次登录 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未登录").font(.caption2).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("详情") { model.editorHost = host }
                Button("SFTP") { model.sftpHost = host }
                Spacer()
                Button("连接") { model.connect(host) }
            }.controlSize(.small)
        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
            .contextMenu { hostMenu(host) }
    }
}
