import SwiftUI
import BozhouCore

private struct TransferRequest: Identifiable {
    let id = UUID()
    let fromLeft: Bool
    let source: String
    let sourceName: String
    let destinationName: String
    let size: UInt64
}

@MainActor
private final class RelayModel: ObservableObject {
    @Published var leftID: UUID?
    @Published var rightID: UUID?
    @Published var leftPath = "/"
    @Published var rightPath = "/"
    @Published var leftFiles: [RemoteFile] = []
    @Published var rightFiles: [RemoteFile] = []
    @Published var leftSelection: String?
    @Published var rightSelection: String?
    @Published var busy = false
    @Published var connected = false
    @Published var transferring = false
    @Published var progress = 0.0
    @Published var transferred: UInt64 = 0
    @Published var status = "选择两台服务器后连接"
    @Published var error: String?
    private var left: SFTPClient?
    private var right: SFTPClient?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func connect(_ model: AppModel) {
        guard !busy, let a = model.hosts.first(where: { $0.id == leftID }),
              let b = model.hosts.first(where: { $0.id == rightID }) else { return }
        cancel()
        let generation = self.generation
        do {
            let left = SFTPClient(launch: try model.builder.build(host: a, hosts: model.hosts, identities: model.identities, sftp: true))
            self.left = left
            let right = SFTPClient(launch: try model.builder.build(host: b, hosts: model.hosts, identities: model.identities, sftp: true))
            self.right = right
            busy = true; status = "正在连接两台服务器…"; error = nil
            task = Task {
                do {
                    let aPath = try await left.connect()
                    let bPath = try await right.connect()
                    let aFiles = try await left.list(aPath)
                    let bFiles = try await right.list(bPath)
                    guard self.generation == generation else { return }
                    leftPath = aPath; rightPath = bPath; leftFiles = aFiles; rightFiles = bFiles
                    connected = true; status = "两台服务器均已连接"
                } catch {
                    guard self.generation == generation else { return }
                    self.error = error.localizedDescription; cancel()
                }
                if self.generation == generation { busy = false }
            }
        } catch { self.error = error.localizedDescription; cancel() }
    }
    func navigate(leftSide: Bool, path: String) {
        guard connected, !busy, let client = leftSide ? left : right else { return }
        busy = true; status = "正在读取目录…"
        let generation = self.generation
        task = Task {
            do {
                let files = try await client.list(path)
                guard self.generation == generation else { return }
                if leftSide { leftFiles = files; leftPath = path; leftSelection = nil }
                else { rightFiles = files; rightPath = path; rightSelection = nil }
                status = "目录已更新"
            } catch { if self.generation == generation { self.error = error.localizedDescription } }
            if self.generation == generation { busy = false }
        }
    }
    func transfer(_ request: TransferRequest, destination: String) {
        guard !busy, connected, let left, let right else { return }
        guard destination.hasPrefix("/"), !destination.contains("\0"), !destination.hasSuffix("/") else {
            error = "目标必须是包含文件名的绝对路径"; return
        }
        let source = request.fromLeft ? left : right
        let target = request.fromLeft ? right : left
        busy = true; transferring = true; progress = 0; transferred = 0
        status = "\(request.sourceName) → \(request.destinationName)"
        let generation = self.generation
        task = Task {
            do {
                try await source.copy(remote: request.source, to: target, path: destination, total: request.size) { done, total in
                    Task { @MainActor in
                        guard self.generation == generation else { return }
                        self.transferred = done
                        self.progress = total == 0 ? 1 : min(1, Double(done) / Double(total))
                    }
                }
                let aFiles = try await left.list(leftPath)
                let bFiles = try await right.list(rightPath)
                guard self.generation == generation else { return }
                progress = 1; status = "传输完成：\(destination)"; leftFiles = aFiles; rightFiles = bFiles
            } catch {
                guard self.generation == generation else { return }
                self.error = error.localizedDescription; status = "传输未完成"
            }
            if self.generation == generation { transferring = false; busy = false }
        }
    }
    func cancel() {
        generation = UUID()
        task?.cancel(); left?.cancel(); right?.cancel()
        left = nil; right = nil; connected = false; busy = false; transferring = false
        leftFiles = []; rightFiles = []; leftSelection = nil; rightSelection = nil
        status = "连接已关闭"
    }
}

struct ServerTransferView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let host: Host
    @StateObject private var relay = RelayModel()
    @State private var request: TransferRequest?
    @State private var destination = ""
    @State private var leftInput = "/"
    @State private var rightInput = "/"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("服务器间传输", systemImage: "arrow.left.arrow.right").font(.headline)
                Spacer()
                Button("连接服务器") { relay.connect(model) }.disabled(relay.busy || relay.leftID == nil || relay.rightID == nil)
                Button("完成") { relay.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HSplitView {
                pane(leftSide: true)
                pane(leftSide: false)
            }
            HStack(spacing: 12) {
                if relay.busy {
                    if relay.transferring {
                        ProgressView(value: relay.progress).frame(width: 170)
                        Text("\(Int(relay.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: relay.transferred), countStyle: .file))").monospacedDigit()
                    } else { ProgressView().controlSize(.small) }
                    Button("取消") { relay.cancel() }
                }
                Text(relay.status).lineLimit(2)
                Spacer()
            }.font(.caption).padding(16).background(.bar)
        }.frame(width: 1040, height: 650)
            .onAppear { relay.leftID = host.id; relay.rightID = model.hosts.first { $0.id != host.id }?.id }
            .onDisappear { relay.cancel() }
            .onChange(of: relay.leftPath) { _, path in leftInput = path }
            .onChange(of: relay.rightPath) { _, path in rightInput = path }
            .alert("确认传输文件？", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } })) {
                TextField("目标绝对路径（含文件名）", text: $destination)
                Button("取消", role: .cancel) { request = nil }
                Button("开始传输") { if let request { relay.transfer(request, destination: destination) }; request = nil }
            } message: {
                Text("\(request?.sourceName ?? "")：\(request?.source ?? "")\n→ \(request?.destinationName ?? "")\n大小：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: request?.size ?? 0), countStyle: .file))\n同名文件不会覆盖。")
            }
            .alert("传输操作未完成", isPresented: Binding(get: { relay.error != nil }, set: { if !$0 { relay.error = nil } })) {
                Button("知道了", role: .cancel) { relay.error = nil }
            } message: { Text(relay.error ?? "") }
    }
    private func pane(leftSide: Bool) -> some View {
        let id = leftSide ? $relay.leftID : $relay.rightID
        let path = leftSide ? $leftInput : $rightInput
        let directory = leftSide ? relay.leftPath : relay.rightPath
        let selection = leftSide ? $relay.leftSelection : $relay.rightSelection
        let files = leftSide ? relay.leftFiles : relay.rightFiles
        return VStack(spacing: 12) {
            Picker(leftSide ? "服务器 A" : "服务器 B", selection: id) {
                Text("选择服务器").tag(Optional<UUID>.none)
                ForEach(model.hosts) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(relay.busy || relay.connected)
            HStack {
                Button {
                    let parent = (directory as NSString).deletingLastPathComponent
                    relay.navigate(leftSide: leftSide, path: parent.isEmpty ? "/" : parent)
                } label: { Image(systemName: "arrow.up") }
                TextField("目录路径", text: path).onSubmit { relay.navigate(leftSide: leftSide, path: path.wrappedValue) }
                Button { relay.navigate(leftSide: leftSide, path: path.wrappedValue) } label: { Image(systemName: "arrow.clockwise") }
            }.disabled(relay.busy || !relay.connected)
            List(files, selection: selection) { file in
                HStack {
                    Image(systemName: file.isDirectory ? "folder.fill" : "doc").foregroundStyle(file.isDirectory ? sea : .secondary)
                    Text(file.name).lineLimit(1)
                    Spacer()
                    if !file.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 5).contentShape(Rectangle()).tag(file.name)
                    .onTapGesture(count: 2) {
                        if file.isDirectory { relay.navigate(leftSide: leftSide, path: joined(directory, file.name)) }
                    }
            }
            Button(leftSide ? "上传 A → B" : "下载 B → A") { propose(leftSide) }
                .disabled(relay.busy || !relay.connected || !files.contains { $0.name == selection.wrappedValue && !$0.isDirectory })
        }.padding(18).frame(minWidth: 400)
    }
    private func joined(_ directory: String, _ file: String) -> String { (directory == "/" ? "" : directory) + "/" + file }
    private func propose(_ fromLeft: Bool) {
        let files = fromLeft ? relay.leftFiles : relay.rightFiles
        let selection = fromLeft ? relay.leftSelection : relay.rightSelection
        guard let file = files.first(where: { $0.name == selection }), !file.isDirectory,
              !file.name.contains("/"), !file.name.contains("\0"), file.name != ".", file.name != ".." else { return }
        let sourceHost = model.hosts.first { $0.id == (fromLeft ? relay.leftID : relay.rightID) }
        let targetHost = model.hosts.first { $0.id == (fromLeft ? relay.rightID : relay.leftID) }
        destination = joined(fromLeft ? relay.rightPath : relay.leftPath, file.name)
        request = TransferRequest(fromLeft: fromLeft, source: joined(fromLeft ? relay.leftPath : relay.rightPath, file.name),
                                  sourceName: sourceHost?.name ?? "", destinationName: targetHost?.name ?? "", size: file.size)
    }
}
