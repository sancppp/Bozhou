import SwiftUI
import BozhouCore

struct LocalEntry: Identifiable {
    var id: String { url.path }
    let url: URL
    let directory: Bool
    let size: Int
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published var localDirectory = URL(fileURLWithPath: "/")
    @Published var localEntries: [LocalEntry] = []
    @Published var remoteDirectory = "/"
    @Published var remoteEntries: [RemoteFile] = []
    @Published var connected = false
    @Published var busy = false
    @Published var status = "尚未连接"
    @Published var error: String?
    @Published var progress: Double = 0
    private var client: SFTPClient?
    private var task: Task<Void, Never>?
    private var log: AppLog?
    private var generation = UUID()
    func connect(model: AppModel, host: Host) {
        guard !busy else { return }
        cancel()
        let generation = self.generation
        log = model.log
        localDirectory = model.workingDirectory
        refreshLocal()
        do {
            let launch = try model.builder.build(host: host, hosts: model.hosts, identities: model.identities, sftp: true)
            let client = SFTPClient(launch: launch); self.client = client
            busy = true; status = "正在连接 \(host.name)…"; error = nil
            task = Task {
                do {
                    let directory = try await client.connect()
                    let entries = try await client.list(directory)
                    guard self.generation == generation else { return }
                    remoteDirectory = directory; remoteEntries = entries
                    connected = true; status = "已连接 · \(host.name)"
                    log?.write("SFTP 已连接：\(host.name)")
                } catch {
                    guard self.generation == generation else { return }
                    self.error = error.localizedDescription; status = "连接失败"; connected = false; client.cancel()
                }
                busy = false
            }
        } catch { self.error = error.localizedDescription }
    }
    func refreshLocal() {
        let directory = localDirectory
        Task {
            do {
                let entries = try await Task.detached { () throws -> [LocalEntry] in
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
                    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                    var rows: [LocalEntry] = []
                    for url in urls {
                        let values = try url.resourceValues(forKeys: keys)
                        rows.append(LocalEntry(url: url, directory: values.isDirectory ?? false, size: values.fileSize ?? 0))
                    }
                    return rows.sorted {
                        if $0.directory != $1.directory { return $0.directory }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
                }.value
                if localDirectory == directory { localEntries = entries }
            } catch { self.error = error.localizedDescription }
        }
    }
    func path(_ name: String) -> String { (remoteDirectory == "/" ? "" : remoteDirectory) + "/" + name }
    func navigate(_ path: String) {
        let generation = self.generation
        operate("正在读取目录…") { client in
            let entries = try await client.list(path)
            guard self.generation == generation else { return }
            self.remoteDirectory = path; self.remoteEntries = entries
        }
    }
    func upload(_ url: URL) {
        let target = path(url.lastPathComponent)
        let generation = self.generation, directory = remoteDirectory
        operate("正在上传 \(url.lastPathComponent)…") { client in
            try await client.upload(local: url, remote: target) { done, total in
                Task { @MainActor in
                    guard self.generation == generation else { return }
                    self.progress = total == 0 ? 1 : min(1, Double(done) / Double(total))
                }
            }
            let entries = try await client.list(directory)
            if self.generation == generation { self.remoteEntries = entries }
        }
    }
    func download(_ file: RemoteFile) {
        let remote = path(file.name), local = localDirectory.appendingPathComponent(file.name)
        let generation = self.generation
        guard file.name != "." && file.name != ".." && !file.name.contains("/") && !file.name.contains("\0") else {
            error = "服务器返回了无效的文件名"; return
        }
        operate("正在下载 \(file.name)…") { client in
            try await client.download(remote: remote, local: local, total: file.size) { done, total in
                Task { @MainActor in
                    guard self.generation == generation else { return }
                    self.progress = total == 0 ? 1 : min(1, Double(done) / Double(total))
                }
            }
            if self.generation == generation { self.refreshLocal() }
        }
    }
    func mkdir(_ name: String) {
        guard validName(name) else { return }
        let target = path(name)
        operateAndRefresh("正在创建目录…") { client in try await client.mkdir(target) }
    }
    func rename(_ file: RemoteFile, name: String) {
        guard validName(name) else { return }
        let from = path(file.name), to = path(name)
        operateAndRefresh("正在重命名…") { client in try await client.rename(from, to: to) }
    }
    func remove(_ file: RemoteFile) {
        let target = path(file.name)
        operateAndRefresh("正在删除…") { client in try await client.remove(target, directory: file.isDirectory) }
    }
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil; client?.cancel(); client = nil
        connected = false; busy = false; remoteEntries = []
        status = "连接已关闭"
    }
    private func validName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            error = "名称不能为空，不能包含 /，也不能为 . 或 .."; return false
        }
        return true
    }
    private func operateAndRefresh(_ title: String, action: @escaping (SFTPClient) async throws -> Void) {
        let generation = self.generation, directory = remoteDirectory
        operate(title) { client in
            try await action(client)
            let entries = try await client.list(directory)
            if self.generation == generation { self.remoteEntries = entries }
        }
    }
    private func operate(_ title: String, action: @escaping (SFTPClient) async throws -> Void) {
        guard !busy, connected, let client else { return }
        let generation = self.generation
        busy = true; status = title; progress = 0; error = nil
        task = Task {
            do {
                try await action(client)
                guard self.generation == generation else { return }
                status = "操作完成"; progress = 1
            }
            catch {
                guard self.generation == generation else { return }
                self.error = error.localizedDescription + (title.contains("上传") ? "\n中断的上传可能留下同名部分文件，请检查后再重试。" : "")
                status = "操作未完成"
                if error.localizedDescription.contains("连接") || error.localizedDescription.contains("超时") || error is CancellationError { connected = false }
                log?.write("SFTP 操作失败：\(error.localizedDescription)")
            }
            busy = false
        }
    }
}

struct SFTPView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let host: Host
    @StateObject private var browser = FileBrowserModel()
    @State private var localSelection: String?
    @State private var remoteSelection: String?
    @State private var remoteInput = "/"
    @State private var showName = false
    @State private var renameTarget: RemoteFile?
    @State private var name = ""
    @State private var deleteTarget: RemoteFile?
    @State private var serverTransfer = false
    private var selectedRemote: RemoteFile? { browser.remoteEntries.first { $0.name == remoteSelection } }
    private var selectedLocal: LocalEntry? { browser.localEntries.first { $0.id == localSelection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(sea)
                VStack(alignment: .leading, spacing: 4) { Text("SFTP · \(host.name)").font(.headline); Text("\(host.username)@\(host.address)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("服务器间传输") { serverTransfer = true }
                if !browser.connected && !browser.busy { Button("重新连接") { browser.connect(model: model, host: host) } }
                Button("完成") { browser.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                localPane
                Divider()
                remotePane
            }
            Divider()
            HStack(spacing: 12) {
                if browser.busy {
                    ProgressView(value: browser.progress).frame(width: 120)
                    Button("取消") { browser.cancel() }.controlSize(.small)
                } else { Image(systemName: browser.connected ? "checkmark.circle" : "circle").foregroundStyle(browser.connected ? .green : .secondary) }
                Text(browser.status).font(.caption)
                Spacer()
                Text("同名文件不会覆盖 · 目录删除仅支持空目录").font(.caption2).foregroundStyle(.secondary)
            }.padding(16).background(.bar)
        }.frame(width: 1000, height: 660).tint(sea)
            .sheet(isPresented: $serverTransfer) { ServerTransferView(host: host).environmentObject(model) }
            .onAppear { browser.connect(model: model, host: host) }
            .onDisappear { browser.cancel() }
            .onChange(of: browser.remoteDirectory) { _, value in remoteInput = value; remoteSelection = nil }
            .alert("SFTP 操作未完成", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(browser.error ?? "") }
            .alert(renameTarget == nil ? "新建远程目录" : "重命名", isPresented: $showName) {
                TextField("名称", text: $name)
                Button("取消", role: .cancel) {}
                Button("确定") {
                    if let target = renameTarget { browser.rename(target, name: name) } else { browser.mkdir(name) }
                }
            }
            .alert("删除远程文件？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { if let target = deleteTarget { browser.remove(target) }; deleteTarget = nil }
            } message: { Text("将从服务器永久删除「\(deleteTarget?.name ?? "")」。") }
    }
    private var localPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("本地文件", systemImage: "laptopcomputer").font(.headline); Spacer(); Button("选择目录") { chooseDirectory() } }
            HStack {
                Button { browser.localDirectory.deleteLastPathComponent(); browser.refreshLocal() } label: { Image(systemName: "arrow.up") }
                Text(browser.localDirectory.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(browser.localDirectory.path)
                Spacer()
                Button { browser.refreshLocal() } label: { Image(systemName: "arrow.clockwise") }
            }
            List(browser.localEntries, selection: $localSelection) { file in
                fileRow(name: file.url.lastPathComponent, directory: file.directory, size: UInt64(file.size))
                    .tag(file.id).contentShape(Rectangle()).onTapGesture(count: 2) {
                        if file.directory { browser.localDirectory = file.url; browser.refreshLocal(); localSelection = nil }
                    }
            }.listStyle(.inset).scrollContentBackground(.hidden)
            HStack {
                Text("\(browser.localEntries.count) 个项目").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { if let file = selectedLocal { browser.upload(file.url) } } label: { Label("上传", systemImage: "arrow.right") }
                    .disabled(browser.busy || !browser.connected || selectedLocal == nil || selectedLocal?.directory == true)
            }
        }.padding(18).frame(maxWidth: .infinity)
    }
    private var remotePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("远程文件", systemImage: "server.rack").font(.headline)
                Spacer()
                Button { name = ""; renameTarget = nil; showName = true } label: { Label("新建目录", systemImage: "folder.badge.plus") }.disabled(browser.busy || !browser.connected)
            }
            HStack {
                Button {
                    let parent = (browser.remoteDirectory as NSString).deletingLastPathComponent
                    browser.navigate(parent.isEmpty ? "/" : parent)
                } label: { Image(systemName: "arrow.up") }
                TextField("远程路径", text: $remoteInput).font(.system(size: 11, design: .monospaced))
                    .onSubmit { browser.navigate(remoteInput) }
                Button { browser.navigate(remoteInput) } label: { Image(systemName: "arrow.clockwise") }
            }.disabled(browser.busy || !browser.connected)
            List(browser.remoteEntries, selection: $remoteSelection) { file in
                fileRow(name: file.name, directory: file.isDirectory, size: file.size)
                    .tag(file.name).contentShape(Rectangle()).onTapGesture(count: 2) {
                        if file.isDirectory { browser.navigate(browser.path(file.name)) }
                    }.contextMenu {
                        Button("下载") { browser.download(file) }.disabled(file.isDirectory || browser.busy || !browser.connected)
                        Button("重命名") { renameTarget = file; name = file.name; showName = true }.disabled(browser.busy || !browser.connected)
                        Button("删除", role: .destructive) { deleteTarget = file }.disabled(browser.busy || !browser.connected)
                    }
            }.listStyle(.inset).scrollContentBackground(.hidden)
            HStack {
                Button { if let file = selectedRemote { browser.download(file) } } label: { Label("下载", systemImage: "arrow.left") }
                    .disabled(browser.busy || !browser.connected || selectedRemote == nil || selectedRemote?.isDirectory == true)
                Spacer()
                Text("\(browser.remoteEntries.count) 个项目").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity)
    }
    private func fileRow(name: String, directory: Bool, size: UInt64) -> some View {
        HStack(spacing: 9) {
            Image(systemName: directory ? "folder.fill" : "doc").foregroundStyle(directory ? sea : .secondary).frame(width: 18)
            Text(name).font(.system(size: 12)).lineLimit(1); Spacer()
            if !directory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { browser.localDirectory = url; browser.refreshLocal() }
    }
}
