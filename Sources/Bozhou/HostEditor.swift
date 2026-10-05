import SwiftUI
import BozhouCore

struct HostEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var environment = ""
    @State private var validation: String?
    @State private var proxyEnabled = false
    @State private var proxy = ProxyConfiguration()
    @State private var jumpSelection: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(sea)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hosts.contains { $0.id == host.id } ? "主机详情" : "新建主机").font(.title3.weight(.semibold))
                    Text("配置连接，留住下一次出发的坐标").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            Form {
                Section("基本信息") {
                    TextField("名称", text: $host.name)
                    TextField("地址", text: $host.address, prompt: Text("example.com / 192.168.1.10"))
                    TextField("端口", value: $host.port, format: .number.grouping(.never))
                    TextField("用户名", text: $host.username)
                    TextField("文件夹路径", text: $host.group, prompt: Text("例如：生产环境/华北"))
                    if !model.groups.isEmpty {
                        Picker("已有文件夹", selection: $host.group) {
                            Text("根目录").tag("")
                            ForEach(Array(Set(model.groups + (host.group.isEmpty ? [] : [host.group]))).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("标签", text: $host.tags, prompt: Text("用空格分隔"))
                    Picker("图标颜色", selection: $host.color) {
                        Text("海蓝").tag("blue"); Text("青绿").tag("mint"); Text("暖橙").tag("orange")
                    }
                    Toggle("星标主机", isOn: $host.favorite)
                }
                Section {
                    Picker("登录方式", selection: $host.authentication) {
                        ForEach(Authentication.allCases) { auth in Text(auth.title).tag(auth) }
                    }
                    if host.authentication == .identity {
                        Picker("私钥", selection: $host.identityID) {
                            Text("请选择").tag(nil as UUID?)
                            ForEach(model.identities) { key in Text(key.name).tag(Optional(key.id)) }
                        }
                        Text("需要对应公钥的私钥文件。请先在「密钥」中导入，或使用 SSH Agent。").font(.caption).foregroundStyle(.secondary)
                    } else if host.authentication == .kerberos {
                        Text("使用本机 Kerberos 票据缓存（kinit / 企业登录）。请填写远端账号；无需密码，不转发票据。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        SecureField("密码", text: $host.password, prompt: Text("留空则在首次连接时输入"))
                        Text(host.authentication == .password
                             ? "密码以明文保存在本地。目标主机与每一级跳板分别复用已保存的用户名和密码。"
                             : "优先使用 SSH Agent；密码回退时复用此密码。首次输入后以明文保存在本地。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("身份验证") }
                Section {
                    ForEach(Array(host.jumpHosts.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
                            Text(model.hosts.first { $0.id == id }?.name ?? "已删除的主机")
                            Spacer()
                            Button {
                                guard let current = host.jumpHosts.firstIndex(of: id), current > 0 else { return }
                                host.jumpHosts.swapAt(current, current - 1)
                            } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                            Button { host.jumpHosts.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        }
                    }
                    HStack {
                        Picker("添加跳板", selection: $jumpSelection) {
                            Text("选择已保存的主机").tag(nil as UUID?)
                            ForEach(model.hosts.filter { $0.id != host.id && !host.jumpHosts.contains($0.id) }) { item in
                                Text(item.name).tag(Optional(item.id))
                            }
                        }
                        Button("添加") {
                            if let id = jumpSelection { host.jumpHosts.append(id); jumpSelection = nil }
                        }.disabled(jumpSelection == nil)
                    }
                    Text("按顺序连接；若跳板自身配置了上级跳板，会自动展开。每一级可使用不同的端口和认证。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("跳板链 · Host Chain") }
                Section("终端环境") {
                    TextField("默认 Shell", text: $host.shell, prompt: Text("留空使用登录 shell"))
                    Text("环境变量（每行 NAME=value）").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $environment).font(.system(size: 12, design: .monospaced)).frame(height: 75)
                    Text("bash / zsh 支持自动交互记录；其他 shell 可使用手动快照。").font(.caption).foregroundStyle(.secondary)
                }
                Section("网络代理") {
                    Toggle("启用代理", isOn: $proxyEnabled)
                    if proxyEnabled {
                        Picker("协议", selection: $proxy.kind) {
                            Text("SOCKS5").tag(ProxyKind.socks5); Text("HTTP CONNECT").tag(ProxyKind.http)
                        }
                        TextField("代理地址", text: $proxy.host)
                        TextField("代理端口", value: $proxy.port, format: .number.grouping(.never))
                        Text("支持无认证代理。代理可配置在直连主机或跳板链第一台主机上。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("本地端口转发") {
                    ForEach(host.forwards) { forward in
                        LocalForwardEditor(forward: $host.forwards.element(forward)) {
                            host.forwards.removeAll { $0.id == forward.id }
                        }
                    }
                    Button("添加转发") { host.forwards.append(LocalForward()) }
                    Text("连接终端时启用，仅监听本机 127.0.0.1，关闭该会话后停止。例如本地 58080 → 服务器 127.0.0.1:80。").font(.caption).foregroundStyle(.secondary)
                }
                Section("登录与系统信息") {
                    LabeledContent("主机名") {
                        Text(host.systemProfile?.hostname ?? "下次登录后采集")
                            .textSelection(.enabled)
                    }
                    LabeledContent("添加时间", value: host.createdAt.formatted())
                    LabeledContent("上次成功登录", value: host.lastLoginAt?.formatted() ?? "尚未登录")
                    if let profile = host.systemProfile {
                        LabeledContent("采集时间", value: profile.collectedAt.formatted())
                        profileField("操作系统", profile.operatingSystem)
                        profileField("内核与架构", profile.kernel)
                        profileField("CPU", profile.cpu)
                        profileField("内存", profile.memory)
                    }
                    Text("每次登录通过只读命令更新主机名、系统、CPU 与内存信息。").font(.caption).foregroundStyle(.secondary)
                }
                Section("备注") { TextEditor(text: $host.notes).frame(height: 55) }
            }.formStyle(.grouped)
            if let validation { Label(validation, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).padding(12) }
            Divider()
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { save(connect: false) }
                Button("保存并连接") { save(connect: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.controlSize(.large).padding(20)
        }.frame(width: 540, height: 740).tint(sea)
            .onAppear {
                environment = host.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                proxyEnabled = host.proxy != nil; proxy = host.proxy ?? ProxyConfiguration()
            }
    }
    private func profileField(_ title: String, _ value: String) -> some View {
        DisclosureGroup(title) {
            Text(value.isEmpty ? "系统未提供此信息" : value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func save(connect: Bool) {
        do {
            var values: [String: String] = [:]
            for line in environment.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let equal = line.firstIndex(of: "=") else { throw BozhouError.invalid("环境变量格式应为 NAME=value") }
                let name = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
                guard values[name] == nil else { throw BozhouError.invalid("环境变量重复：\(name)") }
                values[name] = String(line[line.index(after: equal)...])
            }
            host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
            host.address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
            host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
            host.environment = values; host.proxy = proxyEnabled ? proxy : nil
            try model.saveHost(host)
            if connect { model.connect(host) }
            dismiss()
        } catch { validation = error.localizedDescription }
    }
}

private struct LocalForwardEditor: View {
    @Binding var forward: LocalForward
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Toggle("启用", isOn: $forward.enabled)
                Spacer()
                Button("移除", action: remove)
            }
            TextField("本地端口", value: $forward.localPort, format: .number.grouping(.never))
            TextField("目标地址（从服务器访问）", text: $forward.remoteHost)
            TextField("目标端口", value: $forward.remotePort, format: .number.grouping(.never))
        }
    }
}
