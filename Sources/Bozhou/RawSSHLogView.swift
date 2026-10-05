import SwiftUI

struct RawLogContent: View {
    let url: URL
    @State private var content = ""
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(content.isEmpty ? "Waiting for OpenSSH output…" : content)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
        }.background(.background)
            .task(id: url) {
                while !Task.isCancelled {
                    let snapshot = await Task.detached(priority: .utility) {
                        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
                        defer { try? handle.close() }
                        let length = (try? handle.seekToEnd()) ?? 0
                        try? handle.seek(toOffset: length > 262144 ? length - 262144 : 0)
                        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                    }.value
                    if snapshot != content { content = snapshot }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
}

struct RawSSHLogView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("原始 SSH 日志").font(.headline)
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            RawLogContent(url: url)
            Text(url.path).font(.caption).textSelection(.enabled).padding()
        }.frame(width: 800, height: 520)
    }
}

struct SSHLogsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var files: [URL] = []
    @State private var selected: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeader(title: "SSH 原始日志", detail: "OpenSSH 原文 · 按连接保存 · 预览最后 256 KiB")
                Button("刷新") { load() }
                Button("打开日志目录") { NSWorkspace.shared.open(model.paths.logs) }
            }
            HSplitView {
                List(files, id: \.self, selection: $selected) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.lastPathComponent).font(.caption).lineLimit(2)
                        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                            Text(date, format: .dateTime).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4).tag(url)
                }.frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
                if let selected { RawLogContent(url: selected) }
                else { Text("选择连接日志").frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary) }
            }
        }.padding(28).onAppear { load() }
    }
    private func load() {
        files = ((try? FileManager.default.contentsOfDirectory(at: model.paths.logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".ssh.log") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        if selected == nil { selected = files.first }
    }
}
