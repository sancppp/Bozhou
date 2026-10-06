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
            Picker(L10n.tr("Log type"), selection: $rawSSH) {
                Text(L10n.tr("SSH & Exit Logs")).tag(true)
                Text(L10n.tr("App Events")).tag(false)
            }.pickerStyle(.segmented).frame(width: 300).padding(.top, 20)
            if rawSSH { SSHLogsPage() } else { appEvents }
        }
    }
    private var appEvents: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeader(title: L10n.tr("Logs"), detail: L10n.tr("Connection lifecycle and error events. Passwords, keystrokes and terminal output are not recorded here."))
                Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.log.url]) }
                Button(L10n.tr("Refresh")) { revision += 1 }
            }
            HStack {
                TextField(L10n.tr("Search log messages or categories"), text: $search).textFieldStyle(.roundedBorder)
                Picker(L10n.tr("Level"), selection: $level) {
                    Text(L10n.tr("All levels")).tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 155)
                Picker(L10n.tr("Category"), selection: $category) {
                    Text(L10n.tr("All categories")).tag("")
                    ForEach(Array(Set(entries.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 155)
                Toggle(L10n.tr("Auto refresh"), isOn: $autoRefresh).toggleStyle(.checkbox)
            }
            Table(filtered, selection: $selected) {
                TableColumn(L10n.tr("Time")) { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(85)
                TableColumn(L10n.tr("Level")) { entry in
                    Text(entry.level.title).foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .secondary)
                }.width(55)
                TableColumn(L10n.tr("Category"), value: \.category).width(65)
                TableColumn(L10n.tr("Message"), value: \.message)
            }
            .overlay {
                if filtered.isEmpty { Text(search.isEmpty ? L10n.tr("No logs match these filters") : L10n.tr("No matching logs")).foregroundStyle(.secondary) }
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
            Text(L10n.tr("Records: \(filtered.count) / \(entries.count) · Newest first")).font(.caption).foregroundStyle(.secondary)
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
