import SwiftUI
import BozhouCore

struct LogsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var entries: [LogEntry] = []
    @State private var search = ""
    @State private var level: LogLevel?
    @State private var category = ""
    @State private var selected: UUID?
    @State private var autoRefresh = true
    @State private var revision = 0
    @State private var rawSSH = true
    private var filtered: [LogEntry] { entries.filter { $0.matches(search: search, level: level, category: category) } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("日志类型", selection: $rawSSH) {
                Text("SSH 原始日志").tag(true)
                Text("应用事件").tag(false)
            }.pickerStyle(.segmented).frame(width: 300).padding(.top, 20)
            if rawSSH { SSHLogsPage() } else { appEvents }
        }
    }
    private var appEvents: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeader(title: "运行日志", detail: "连接生命周期与错误记录；不记录密码、按键或终端输出。")
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.log.url]) }
                Button("刷新") { revision += 1 }
            }
            HStack {
                TextField("搜索日志内容或分类", text: $search).textFieldStyle(.roundedBorder)
                Picker("级别", selection: $level) {
                    Text("全部级别").tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 155)
                Picker("分类", selection: $category) {
                    Text("全部分类").tag("")
                    ForEach(Array(Set(entries.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 155)
                Toggle("自动刷新", isOn: $autoRefresh).toggleStyle(.checkbox)
            }
            Table(filtered, selection: $selected) {
                TableColumn("时间") { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(85)
                TableColumn("级别") { entry in
                    Text(entry.level.title).foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .secondary)
                }.width(55)
                TableColumn("分类", value: \.category).width(65)
                TableColumn("内容", value: \.message)
            }
            .overlay {
                if filtered.isEmpty { Text(search.isEmpty ? "暂无符合筛选条件的日志" : "没有匹配的日志").foregroundStyle(.secondary) }
            }
            if let entry = entries.first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(entry.message).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(maxHeight: 120)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("\(filtered.count) / \(entries.count) 条 · 最新记录在前").font(.caption).foregroundStyle(.secondary)
        }.padding(28)
            .task(id: revision) { await load() }
            .task(id: autoRefresh) {
                guard autoRefresh else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await load()
                }
            }
    }
    private func load() async {
        let log = model.log
        let result = await Task.detached(priority: .utility) { log.entries() }.value
        guard !Task.isCancelled else { return }
        // Avoid rebuilding native menus/selection every tick, including legacy rows without IDs.
        let unchanged = result.count == entries.count && zip(result, entries).allSatisfy {
            $0.date == $1.date && $0.level == $1.level && $0.category == $1.category && $0.message == $1.message
        }
        if !unchanged { entries = result }
    }
}
