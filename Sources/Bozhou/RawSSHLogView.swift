import SwiftUI
import BozhouCore

struct RawLogContent: View {
    let url: URL
    @State private var content = ""
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(content.isEmpty ? L10n.tr("Waiting for log content…") : content)
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
    var title = L10n.tr("Raw SSH Log")
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(L10n.tr("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
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
                PageHeader(title: L10n.tr("SSH & Exit Logs"), detail: L10n.tr("Raw OpenSSH logs and exit context · Latest 20 context reports · Preview last 256 KiB"))
                Button(L10n.tr("Refresh")) { load() }
                Button(L10n.tr("Open Log Directory")) { NSWorkspace.shared.open(model.paths.logs) }
            }
            HSplitView {
                List(files, id: \.self, selection: $selected) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        if url.lastPathComponent.hasSuffix(".terminal-context.json") {
                            Text(L10n.tr("Exit Context")).font(.caption).foregroundStyle(.orange)
                        }
                        Text(url.lastPathComponent).font(.caption).lineLimit(2)
                        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                            Text(date, format: .dateTime).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4).tag(url)
                }.frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
                if let selected { RawLogContent(url: selected) }
                else { Text(L10n.tr("Select a connection log")).frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary) }
            }
        }.padding(28).onAppear { load() }
    }
    private func load() {
        files = ((try? FileManager.default.contentsOfDirectory(at: model.paths.logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".ssh.log") || $0.lastPathComponent.hasSuffix(".terminal-context.json") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        if selected == nil { selected = files.first }
    }
}
