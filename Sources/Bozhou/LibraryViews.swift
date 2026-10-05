import SwiftUI
import UniformTypeIdentifiers
import BozhouCore

struct IdentitiesPage: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Identity?
    @State private var deleting: Identity?
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                PageHeader(title: "密钥", detail: "让每一把密钥，都有清晰的归属。私钥保留在你选择的位置。")
                Button { importKey() } label: { Label("导入密钥", systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(importing)
            }
            if model.identities.isEmpty {
                EmptyState(symbol: "key.horizontal", title: "你的连接凭据", detail: "导入已有私钥，或选择公钥并自动匹配同目录的私钥。") {
                    Button("选择密钥文件") { importKey() }.disabled(importing)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.identities) { key in
                    HStack(spacing: 16) {
                        Image(systemName: "key.fill").foregroundStyle(sea).font(.title2).frame(width: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(key.name).font(.headline)
                            Text(key.privateKeyPath.isEmpty ? "仅公钥 · 认证时使用 SSH Agent 或关联的本地私钥" : key.privateKeyPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            if !key.fingerprint.isEmpty { Text(key.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        Button("公钥") { selected = key }
                        Button { deleting = key } label: { Image(systemName: "trash") }.help("移除密钥记录")
                    }.padding(.vertical, 12)
                }.scrollContentBackground(.hidden)
            }
        }.padding(28)
        .sheet(item: $selected) { key in
            VStack(alignment: .leading, spacing: 18) {
                Text(key.name).font(.title2)
                Text(key.publicKey.isEmpty ? "未找到同名 .pub 文件。可使用 ssh-keygen -y 从私钥导出公钥。" : key.publicKey)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    if !key.publicKey.isEmpty { Button("复制公钥") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.publicKey, forType: .string) } }
                    Spacer(); Button("完成") { selected = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 560)
        }
        .alert("移除密钥记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                guard let deleting else { return }
                model.perform {
                    guard !model.hosts.contains(where: { $0.identityID == deleting.id }) else { throw BozhouError.invalid("该密钥仍被主机使用，请先更换认证配置") }
                    try model.store.delete(Identity.self, id: deleting.id); try model.reload()
                }
                self.deleting = nil
            }
        } message: { Text("仅移除应用中的记录，密钥文件会保留。") }
    }
    private func importKey() {
        let panel = NSOpenPanel(); panel.title = "选择 SSH 私钥或公钥"; panel.message = "支持仅导入公钥；同目录存在对应私钥时会保存路径引用"; panel.prompt = "导入"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let candidate = url.path.hasSuffix(".pub") ? String(url.path.dropLast(4)) : url.path
        let privatePath = FileManager.default.isReadableFile(atPath: candidate) ? candidate : ""
        importing = true
        Task {
            let key = await Task.detached {
                let pub = (try? String(contentsOf: url.path.hasSuffix(".pub") ? url : URL(fileURLWithPath: privatePath + ".pub"), encoding: .utf8)) ?? ""
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-lf", url.path]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
                var fingerprint = ""
                if (try? process.run()) != nil {
                    fingerprint = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    process.waitUntilExit()
                }
                return Identity(name: URL(fileURLWithPath: candidate).lastPathComponent, privateKeyPath: privatePath, publicKey: pub, fingerprint: fingerprint)
            }.value
            model.perform {
                guard !key.fingerprint.isEmpty else { throw BozhouError.invalid("无法识别 SSH 密钥，请检查所选文件") }
                if model.identities.contains(where: { $0.fingerprint == key.fingerprint }) { model.notify("此密钥已经导入"); return }
                try model.store.save(key); try model.reload(); model.notify("密钥已导入")
            }
            importing = false
        }
    }
}

struct SnippetsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Snippet?
    @State private var deleting: Snippet?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                PageHeader(title: "快捷命令", detail: "把常用命令收好，在终端中一键填入，确认后执行。")
                Button { editing = Snippet() } label: { Label("新建命令", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            if model.snippets.isEmpty {
                EmptyState(symbol: "curlybraces", title: "少一些重复输入", detail: "部署检查、日志查询、系统诊断，都可以成为你的快捷命令。") {
                    Button("新建命令") { editing = Snippet() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.snippets) { snippet in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(snippet.name).font(.headline)
                                    Spacer()
                                    Button("编辑") { editing = snippet }
                                    Button { deleting = snippet } label: { Image(systemName: "trash") }
                                }
                                Text(snippet.command).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                if !snippet.detail.isEmpty { Text(snippet.detail).font(.caption).foregroundStyle(.secondary) }
                                if !model.sessions.filter({ !$0.ended }).isEmpty {
                                    Menu("填入终端") {
                                        ForEach(model.sessions.filter { !$0.ended }) { session in
                                            Button(session.displayName.full) { model.activeSession = session.id; session.send(snippet.command) }
                                        }
                                    }.fixedSize()
                                }
                            }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
        }.padding(28)
            .sheet(item: $editing) { snippet in SnippetEditor(snippet: snippet).environmentObject(model) }
            .alert("删除快捷命令？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let deleting { model.perform { try model.store.delete(Snippet.self, id: deleting.id); try model.reload() } }; deleting = nil
                }
            }
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var snippet: Snippet
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("快捷命令").font(.title2.weight(.semibold))
            TextField("名称", text: $snippet.name)
            TextEditor(text: $snippet.command).font(.system(size: 13, design: .monospaced)).frame(height: 150).border(.quaternary)
            TextField("说明（可选）", text: $snippet.detail)
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("保存") {
                    model.perform { try model.store.save(snippet); try model.reload(); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty || snippet.command.isEmpty)
            }
        }.padding(28).frame(width: 520)
    }
}

struct InteractionDetail: View {
    @EnvironmentObject var model: AppModel
    let item: Interaction
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { HostNameLabel(model.displayName(for: item)).font(.headline); Spacer(); Text(item.date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
            HStack { Text(item.shell); Spacer(); Text(item.exitCode.map { "退出状态 \($0)" } ?? "未完成 / 手动快照") }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(item.command).font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            Divider()
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    Text(item.output.isEmpty ? "（无输出）" : item.output).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            if item.truncated { Text("输出超过 256 KiB，已截断").font(.caption).foregroundStyle(.orange) }
        }.padding(22).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PinsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Set<UUID> = []
    @State private var deleting: Pin?
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "交互收藏", detail: "收藏每一次有价值的交互。选择两条，并排查看命令与结果。")
            if model.pins.isEmpty {
                EmptyState(symbol: "pin", title: "值得留下的那一次", detail: "在终端交互侧栏点击图钉，即可完整保存时间、命令和输出。") { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack {
                        TextField("搜索收藏", text: $search).textFieldStyle(.roundedBorder)
                        List(model.pins.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || model.displayName(for: $0.interaction).full.localizedCaseInsensitiveContains(search) }, selection: $selection) { pin in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(pin.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    HostNameLabel(model.displayName(for: pin.interaction)).font(.caption2).foregroundStyle(.secondary)
                                    Text(pin.interaction.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button {
                                    if selection.contains(pin.id) { selection.remove(pin.id) }
                                    else if selection.count < 2 { selection.insert(pin.id) }
                                } label: {
                                    Image(systemName: selection.contains(pin.id) ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.plain).help("加入或移出对比").accessibilityLabel("对比：\(pin.title)")
                            }.padding(.vertical, 6).tag(pin.id).contextMenu {
                                Button("导出 Markdown") { export(pin) }
                                Button("删除", role: .destructive) { deleting = pin }
                            }
                        }.scrollContentBackground(.hidden)
                        Text("勾选两条，或按 ⌘ 多选进行对比").font(.caption).foregroundStyle(.secondary)
                    }.frame(minWidth: 190, idealWidth: 220, maxWidth: 270)
                    HStack(spacing: 12) {
                        let chosen = Array(model.pins.filter { selection.contains($0.id) }.prefix(2))
                        if chosen.isEmpty { Text("选择一条收藏查看详情").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        if chosen.count == 2 {
                            OutputComparisonView(before: chosen[1].interaction, after: chosen[0].interaction)
                        } else if let pin = chosen.first {
                            InteractionDetail(item: pin.interaction).frame(minWidth: 200)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.leading, 12)
                }
            }
        }.padding(28)
        .alert("删除这条收藏？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let deleting { model.perform { try model.store.delete(Pin.self, id: deleting.id); try model.reload() } }; deleting = nil
            }
        }
    }
    private func export(_ pin: Pin) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "交互收藏.md"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let item = pin.interaction
        // A fence longer than any content run preserves embedded Markdown fences.
        let longest = (item.command + item.output).split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let text = "# \(model.displayName(for: item).full)\n\n时间：\(item.date.formatted())\n\n\(item.shell)\n\n\(fence)sh\n\(item.command)\n\(fence)\n\n\(fence)text\n\(item.output)\n\(fence)\n"
        model.perform { try text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: UUID?
    @State private var search = ""
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PageHeader(title: "命令历史", detail: "按实际执行记录，最多保留 \(model.settings.historyLimit) 条。")
                Button("清空历史") { confirmClear = true }.disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "每一步，都有迹可循", detail: "连接并执行命令后，历史会显示在这里。你可以在设置中关闭保存。") { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("搜索命令或主机", text: $search).textFieldStyle(.roundedBorder)
                HSplitView {
                    List(model.history.filter { search.isEmpty || $0.command.localizedCaseInsensitiveContains(search) || model.displayName(for: $0).full.localizedCaseInsensitiveContains(search) }, selection: $selection) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.command).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                            HostNameLabel(model.displayName(for: item)).font(.caption2).foregroundStyle(.secondary)
                            Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(item.id).contextMenu { Button("收藏交互") { model.pin(item) } }
                    }.frame(minWidth: 220, idealWidth: 280, maxWidth: 350).scrollContentBackground(.hidden)
                    if let item = model.history.first(where: { $0.id == selection }) {
                        VStack { InteractionDetail(item: item); Button("收藏这次交互") { model.pin(item) } }.padding(.leading, 16)
                    } else { Text("选择一条命令查看完整输出").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }.padding(28)
            .alert("清空全部命令历史？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { model.perform { try model.store.clearHistory(); try model.reload() } }
            } message: { Text("已收藏的交互会保留。") }
    }
}

struct KnownHostsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PageHeader(title: "已知主机", detail: "首次连接确认指纹后保存；指纹变化会阻止连接。")
                Button("刷新") { load() }
            }
            Text("主机名采用哈希保存。若服务器合法更换密钥，请先通过可信渠道核实新指纹，再使用下方命令移除对应旧记录。").font(.caption).foregroundStyle(.secondary)
            Text("ssh-keygen -R '[服务器地址]:端口' -f '\(model.paths.knownHosts.path)'").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            ScrollView([.vertical, .horizontal]) {
                Text(content.isEmpty ? "尚未信任任何主机" : content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
        }.padding(28).onAppear { load() }
    }
    private func load() { model.perform { content = try String(contentsOf: model.paths.knownHosts, encoding: .utf8) } }
}

struct PreferencesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var fontSearch = ""
    @State private var backgroundInput = ""
    @State private var newLocation: URL?
    private var terminalBackground: NSColor {
        TerminalAppearance.background(hex: model.settings.terminalBackgroundHex, dark: colorScheme == .dark)
    }
    private func applyBackgroundInput() {
        if let color = TerminalAppearance.color(hex: backgroundInput) {
            model.settings.terminalBackgroundHex = TerminalAppearance.hex(color)
            backgroundInput = TerminalAppearance.hex(color)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "设置", detail: "让泊舟，适合你的工作节奏。").padding(.horizontal, 28).padding(.top, 28)
            Form {
                Section("外观与终端") {
                    Picker("外观", selection: $model.settings.appearance) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }
                    TextField("搜索系统字体", text: $fontSearch)
                    Picker("终端字体", selection: $model.settings.fontName) {
                        ForEach(TerminalAppearance.fonts.filter { fontSearch.isEmpty || $0.localizedCaseInsensitiveContains(fontSearch) || $0 == model.settings.fontName }, id: \.self) { Text($0).tag($0) }
                    }
                    HStack { Text("终端字号"); Slider(value: $model.settings.fontSize, in: 10...36, step: 1); Text("\(Int(model.settings.fontSize)) pt").monospacedDigit().frame(width: 45) }
                    ColorPicker("终端背景", selection: Binding(
                        get: { Color(nsColor: terminalBackground) },
                        set: { model.settings.terminalBackgroundHex = TerminalAppearance.hex(NSColor($0)) }
                    ), supportsOpacity: false)
                    HStack {
                        TextField("背景色值", text: $backgroundInput, prompt: Text("#F1F2F4"))
                            .onSubmit { applyBackgroundInput() }
                        Button("应用颜色") { applyBackgroundInput() }
                            .disabled(TerminalAppearance.color(hex: backgroundInput) == nil)
                        Button("恢复默认") {
                            model.settings.terminalBackgroundHex = nil
                            backgroundInput = TerminalAppearance.hex(terminalBackground)
                        }
                    }
                    Text("颜色立即应用到所有终端。默认浅灰，深色外观使用深灰；文字颜色随背景明暗调整。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("泊舟 Bozhou 你好 · printf 'Hello 世界' → 0123456789")
                        .font(Font(TerminalAppearance.font(model.settings))).textSelection(.enabled)
                        .foregroundStyle(Color(nsColor: TerminalAppearance.foreground(on: terminalBackground)))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color(nsColor: terminalBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                Section("连接") {
                    Toggle("连接中断后自动重连", isOn: $model.settings.autoReconnect)
                    Text("依次等待 5、10、30、60、120 秒重试，五次失败后需手动重连。可随时停止；重连会新建远程 shell，已记录的交互保留。").font(.caption).foregroundStyle(.secondary)
                }
                Section("历史与通知") {
                    Toggle("保存命令历史与输出", isOn: $model.settings.saveHistory)
                    Text("命令与输出可能含业务数据。关闭后不再写入历史；当前会话仍可手动收藏。").font(.caption).foregroundStyle(.secondary)
                    Picker("历史保留条数", selection: $model.settings.historyLimit) {
                        Text("500 条").tag(500); Text("1000 条").tag(1000); Text("3000 条").tag(3000)
                    }
                    Toggle("连接结束时发送系统通知", isOn: $model.settings.notifications)
                }
                Section("本地数据") {
                    Text(model.paths.root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button("在访达中打开") { NSWorkspace.shared.open(model.paths.root) }
                    Button("更改数据位置…") {
                        let panel = NSOpenPanel()
                        panel.title = "选择空的数据目录"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                        if panel.runModal() == .OK { newLocation = panel.url }
                    }
                    Text("数据库包含明文保存的主机密码。主机指纹和运行日志也存储于此；私钥保留在原位置。").font(.caption).foregroundStyle(.secondary)
                }
                Section("关于泊舟") {
                    HStack(spacing: 16) { BrandMark(size: 46); VStack(alignment: .leading, spacing: 5) {
                        Text("泊舟 Bozhou  \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建")").font(.headline)
                        Text("SwiftUI · OpenSSH · SwiftTerm · SQLite").font(.caption).foregroundStyle(.secondary)
                    } }
                    Text("每一次连接，皆有所归。").font(.caption).foregroundStyle(.secondary)
                    Link(destination: AppLinks.repository) {
                        Label(AppLinks.repositoryDisplayName, systemImage: "link")
                    }.font(.caption)
                }
            }.formStyle(.grouped)
        }.onChange(of: model.settings) { _, _ in model.saveSettings() }
            .onAppear { backgroundInput = TerminalAppearance.hex(terminalBackground) }
            .onChange(of: model.settings.terminalBackgroundHex) { _, _ in backgroundInput = TerminalAppearance.hex(terminalBackground) }
            .onChange(of: colorScheme) { _, _ in backgroundInput = TerminalAppearance.hex(terminalBackground) }
            .alert("迁移本地数据？", isPresented: Binding(get: { newLocation != nil }, set: { if !$0 { newLocation = nil } })) {
                Button("取消", role: .cancel) { newLocation = nil }
                Button("迁移并使用") { if let newLocation { model.changeDataLocation(to: newLocation) }; newLocation = nil }
            } message: { Text("数据库、指纹和日志将复制到 \(newLocation?.path ?? "")，立即切换并记住新位置。原目录保留。请先关闭所有会话。") }
    }
}
