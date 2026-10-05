import AppKit
import SwiftUI
import UserNotifications
import BozhouCore

typealias Host = BozhouCore.Host

enum Page: String, CaseIterable, Identifiable {
    case hosts = "主机", identities = "密钥", snippets = "快捷命令", pins = "交互收藏", history = "命令历史", knownHosts = "已知主机", logs = "运行日志", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .hosts: return "server.rack"
        case .identities: return "key.horizontal"
        case .snippets: return "curlybraces"
        case .pins: return "pin"
        case .history: return "clock.arrow.circlepath"
        case .knownHosts: return "checkmark.shield"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var paths: AppPaths
    private(set) var store: Store
    private(set) var log: AppLog
    let workingDirectory: URL
    @Published var hosts: [Host] = []
    @Published var folders: [HostFolder] = []
    @Published var identities: [Identity] = []
    @Published var snippets: [Snippet] = []
    @Published var history: [Interaction] = []
    @Published var pins: [Pin] = []
    @Published var settings: AppSettings
    @Published var page: Page = .hosts
    @Published var selectedGroup = ""
    @Published var hostSort: HostSort = .folders
    @Published var sortAscending = true
    @Published var search = ""
    @Published var sessions: [TerminalSession] = []
    @Published var activeSession: UUID?
    @Published var focusedSession: UUID?
    @Published var splitSession: UUID?
    @Published var splitVertical = false
    @Published var editorHost: Host?
    @Published var sftpHost: Host?
    @Published var error: String?
    @Published var toast: String?

    var builder: ConnectionBuilder {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BozhouAskPass").path
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("BozhouAskPass").path
        return ConnectionBuilder(paths: paths, askPass: FileManager.default.isExecutableFile(atPath: bundled) ? bundled : sibling)
    }
    var active: TerminalSession? { sessions.first { $0.id == activeSession } }
    var commandSession: TerminalSession? {
        if let focusedSession, focusedSession == activeSession || focusedSession == splitSession {
            return sessions.first { $0.id == focusedSession }
        }
        return active
    }
    func displayName(for item: Interaction) -> HostDisplayName {
        HostDisplayName(name: item.hostName, hostname: item.hostname ?? hosts.first { $0.id == item.hostID }?.displayName.hostname)
    }
    var groups: [String] { Array(Set(folders.map(\.path) + hosts.flatMap { HostTree.ancestors($0.group) })).sorted() }
    var filteredHosts: [Host] {
        HostTree.sorted(hosts.filter {
            HostTree.contains($0.group, in: selectedGroup) &&
            (search.isEmpty || [$0.name, $0.systemProfile?.hostname ?? "", $0.address, $0.username, $0.tags]
                .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }, by: hostSort, ascending: sortAscending)
    }
    var colorScheme: ColorScheme? {
        settings.appearance == "dark" ? .dark : settings.appearance == "light" ? .light : nil
    }
    init() throws {
        let env = ProcessInfo.processInfo.environment["BOZHOU_DATA_DIR"]
        workingDirectory = env == nil ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let location = env ?? UserDefaults.standard.string(forKey: "workspacePath")
        let paths = try AppPaths(root: location.map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("Bozhou"))
        self.paths = paths
        store = try Store(url: paths.database)
        log = AppLog(paths: paths)
        settings = try store.loadSettings()
        if NSFont(name: settings.fontName, size: settings.fontSize) == nil { settings.fontName = "Menlo-Regular" }
        try reload()
        log.write("应用启动")
    }
    func reload() throws {
        hosts = try store.list(Host.self); folders = try store.list(HostFolder.self); identities = try store.list(Identity.self)
        snippets = try store.list(Snippet.self); history = try store.list(Interaction.self); pins = try store.list(Pin.self)
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { report(error) }
    }
    func report(_ error: Error) {
        self.error = error.localizedDescription
        log.write("操作失败：\(error.localizedDescription)", level: .error)
    }
    func saveHost(_ host: Host) throws {
        var host = host
        host.group = try HostTree.normalize(host.group)
        try builder.validate(host, hosts: hosts.filter { $0.id != host.id } + [host], identities: identities)
        try store.transaction {
            try ensureFolders(host.group)
            try store.save(host)
        }
        try reload()
        editorHost = nil; notify("主机已保存")
    }
    func deleteHost(_ host: Host) {
        perform {
            guard !hosts.contains(where: { $0.id != host.id && $0.jumpHosts.contains(host.id) }) else {
                throw BozhouError.invalid("该主机仍被其他主机用作跳板，请先移除引用")
            }
            try store.delete(Host.self, id: host.id); try reload()
        }
    }
    func connect(_ host: Host) {
        perform {
            hosts = try store.list(Host.self)
            let host = hosts.first { $0.id == host.id } ?? host
            let launch = try builder.build(host: host, hosts: hosts, identities: identities)
            let session = TerminalSession(host: host, launch: launch, settings: settings, directory: workingDirectory)
            session.makeLaunch = { [weak self] in
                guard let self else { throw BozhouError.cancelled }
                hosts = try store.list(Host.self)
                let current = hosts.first { $0.id == host.id } ?? host
                return try builder.build(host: current, hosts: hosts, identities: identities)
            }
            session.onReady = { [weak self] profile in
                guard let self, var current = try? self.store.list(Host.self).first(where: { $0.id == host.id }) else { return }
                current.lastLoginAt = Date()
                current.systemProfile = profile
                self.perform { try self.store.save(current); try self.reload() }
            }
            session.onExit = { [weak self] message in
                self?.log.write("\(host.name): \(message)", level: .warning, category: "SSH lifecycle")
                self?.sendNotification(title: "连接已结束", body: host.name)
            }
            session.onLifecycle = { [weak self] message in self?.log.write("\(host.name): \(message)", category: "SSH lifecycle") }
            addSession(session)
            log.write("Connecting \(host.name) \(host.address):\(host.port)", category: "SSH lifecycle")
        }
    }
    func localTerminal() {
        perform {
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let directory = paths.sessions.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
            var local = Host(); local.shell = "/bin/zsh"
            let launch = SSHLaunch(executable: "/bin/sh", arguments: ["-c", ShellIntegration.bootstrap(host: local, token: id, local: true)], environment: env, directory: directory, token: id)
            let session = TerminalSession(host: nil, launch: launch, settings: settings, directory: workingDirectory)
            addSession(session)
        }
    }
    func addSession(_ session: TerminalSession) {
        session.onInteraction = { [weak self] interaction in self?.record(interaction) }
        session.onFocus = { [weak self, weak session] in self?.focusedSession = session?.id }
        session.onCompletion = { [weak self, weak session] in
            // Let SwiftTerm finish delivering its process callback before unmounting the view.
            DispatchQueue.main.async { [weak self, weak session] in
                guard let session else { return }
                self?.closeSession(session.id)
            }
        }
        sessions.append(session); activeSession = session.id; focusedSession = session.id; splitSession = nil
    }
    func closeSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.close()
        sessions.removeAll { $0.id == id }
        if activeSession == id {
            activeSession = splitSession.flatMap { other in sessions.first { $0.id == other }?.id } ?? sessions.last?.id
            splitSession = nil
        } else if splitSession == id { splitSession = nil }
        if focusedSession == id { focusedSession = activeSession }
        if sessions.isEmpty { page = .hosts }
    }
    func closeAll() { for session in sessions { session.close(immediately: true) }; sessions = []; activeSession = nil; focusedSession = nil; splitSession = nil }
    func record(_ interaction: Interaction) {
        guard settings.saveHistory else { return }
        perform {
            try store.save(interaction)
            try store.trimHistory(limit: settings.historyLimit)
            history.insert(interaction, at: 0)
            if history.count > settings.historyLimit {
                history.removeLast(history.count - settings.historyLimit)
            }
        }
    }
    func pin(_ interaction: Interaction) {
        var interaction = interaction
        interaction.hostname = displayName(for: interaction).hostname
        guard !pins.contains(where: { $0.interaction.command == interaction.command && $0.interaction.output == interaction.output }) else {
            notify("相同命令和输出已经收藏"); return
        }
        perform { try store.save(Pin(interaction)); pins = try store.list(Pin.self); notify("已保存到交互收藏") }
    }
    private func ensureFolders(_ path: String) throws {
        let existing = Set(try store.list(HostFolder.self).map(\.path))
        for path in HostTree.ancestors(path) where !existing.contains(path) { try store.save(HostFolder(path: path)) }
    }
    func createFolder(_ path: String) {
        perform {
            let normalized = try HostTree.normalize(path)
            guard !normalized.isEmpty else { throw BozhouError.invalid("请输入文件夹名称") }
            try ensureFolders(normalized); try reload()
        }
    }
    func setHostGroupExpanded(_ path: String, expanded: Bool) {
        guard settings.expandedHostGroups.contains(path) != expanded else { return }
        perform {
            var updated = settings
            if expanded { updated.expandedHostGroups.insert(path) }
            else { updated.expandedHostGroups.remove(path) }
            try store.saveSettings(updated)
            settings = updated
        }
    }
    func renameFolder(_ path: String, to destination: String) {
        perform {
            let target = try HostTree.normalize(destination)
            guard !target.isEmpty, target != path, !HostTree.contains(target, in: path), !groups.contains(target) else {
                throw BozhouError.invalid("目标文件夹已存在，或路径无效")
            }
            var updated = settings
            updated.expandedHostGroups = Set(settings.expandedHostGroups.map {
                HostTree.contains($0, in: path) ? target + $0.dropFirst(path.count) : $0
            })
            try store.transaction {
                for var folder in folders where HostTree.contains(folder.path, in: path) {
                    folder.path = target + folder.path.dropFirst(path.count)
                    try store.save(folder)
                }
                for var host in hosts where HostTree.contains(host.group, in: path) {
                    host.group = target + host.group.dropFirst(path.count)
                    try store.save(host)
                }
                try ensureFolders(target)
                try store.saveSettings(updated)
            }
            settings = updated
            if HostTree.contains(selectedGroup, in: path) { selectedGroup = target + selectedGroup.dropFirst(path.count) }
            try reload()
        }
    }
    func deleteFolder(_ path: String) {
        perform {
            guard !hosts.contains(where: { HostTree.contains($0.group, in: path) }),
                  !groups.contains(where: { $0 != path && HostTree.contains($0, in: path) }) else {
                throw BozhouError.invalid("只能删除空文件夹，请先移动其中的主机或子文件夹")
            }
            var updated = settings
            updated.expandedHostGroups = settings.expandedHostGroups.filter { !HostTree.contains($0, in: path) }
            try store.transaction {
                for folder in folders where folder.path == path { try store.delete(HostFolder.self, id: folder.id) }
                try store.saveSettings(updated)
            }
            settings = updated
            if selectedGroup == path { selectedGroup = HostTree.parent(path) }
            try reload()
        }
    }
    func changeDataLocation(to url: URL) {
        perform {
            guard sessions.isEmpty, sftpHost == nil else { throw BozhouError.storage("请先关闭所有终端和 SFTP 会话") }
            guard ProcessInfo.processInfo.environment["BOZHOU_DATA_DIR"] == nil else {
                throw BozhouError.storage("当前通过 BOZHOU_DATA_DIR 指定目录，请移除此环境变量后再更改")
            }
            let copied = try WorkspaceLocation.copy(store: store, from: paths, to: url)
            let newStore = try Store(url: copied.database)
            store = newStore; paths = copied; log = AppLog(paths: copied)
            UserDefaults.standard.set(copied.root.path, forKey: "workspacePath")
            try reload(); notify("已切换数据位置，原目录保留")
        }
    }
    func saveSettings() {
        perform { try store.saveSettings(settings) }
        for session in sessions { session.apply(settings) }
        if settings.notifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
    func notify(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(3)); if toast == text { toast = nil } }
    }
    func sendNotification(title: String, body: String) {
        guard settings.notifications else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
