import AppKit
import SwiftUI
import SwiftTerm
import BozhouCore

final class RecordingTerminalView: NativeInputTerminalView {
    var recorder: InteractionRecorder?
    var onFocus: (() -> Void)?
    var theme = "light"
    var backgroundHex: String?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return accepted
    }
    override func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = recorder?.feed(Array(slice)) ?? Array(slice)
        if !bytes.isEmpty { super.dataReceived(slice: bytes[...]) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    func applyColors() {
        let dark = theme == "dark" || (theme == "system" && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        nativeBackgroundColor = TerminalAppearance.background(hex: backgroundHex, dark: dark)
        nativeForegroundColor = TerminalAppearance.foreground(on: nativeBackgroundColor)
        caretColor = nativeForegroundColor
    }
    func clearScreen() {
        // Feed display controls locally, leaving the remote shell and command recorder untouched.
        feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let host: Host?
    private var launch: SSHLaunch
    let directory: URL
    @Published private(set) var terminal: RecordingTerminalView
    private var recorder: InteractionRecorder
    @Published var status = "正在连接"
    @Published var connected = false
    @Published var ended = false
    @Published var recent: [Interaction] = []
    @Published var shell = ""
    @Published private(set) var reconnecting = false
    var onInteraction: ((Interaction) -> Void)?
    var onExit: ((String) -> Void)?
    var onLifecycle: ((String) -> Void)?
    var onReady: ((SystemProfile?) -> Void)?
    var onFocus: (() -> Void)?
    private var profile: SystemProfile?
    var logURL: URL? { launch.logURL }
    var makeLaunch: (() throws -> SSHLaunch)?
    private var settings: AppSettings
    private var retry = ReconnectPolicy()
    private var retryTask: Task<Void, Never>?
    private var readyAt: Date?
    private var closed = false
    private var started = false
    var title: String { host?.name ?? "本地终端" }
    init(host: Host?, launch: SSHLaunch, settings: AppSettings, directory: URL) {
        self.host = host; self.launch = launch; self.directory = directory; self.settings = settings
        terminal = RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        recorder = InteractionRecorder(token: launch.token, hostID: host?.id, hostName: host?.name ?? "本地终端", sessionID: id)
        super.init()
        configureTerminal()
    }
    private func configureTerminal() {
        terminal.recorder = recorder
        terminal.processDelegate = self
        terminal.onFocus = { [weak self] in self?.onFocus?() }
        apply(settings)
        terminal.optionAsMetaKey = true
        terminal.setAccessibilityLabel("交互终端")
        recorder.onReady = { [weak self] shell in
            guard let self else { return }
            self.shell = shell; status = "已连接"; connected = true
            reconnecting = false; readyAt = Date()
            onLifecycle?("Shell ready: \(shell)")
            onReady?(profile)
        }
        recorder.onSystemProfile = { [weak self] in self?.profile = $0 }
        recorder.onInteraction = { [weak self] interaction in
            guard let self else { return }
            recent.insert(interaction, at: 0)
            if recent.count > 100 { recent.removeLast(recent.count - 100) }
            onInteraction?(interaction)
        }
    }
    func apply(_ settings: AppSettings) {
        self.settings = settings
        terminal.font = TerminalAppearance.font(settings)
        terminal.theme = settings.appearance
        terminal.backgroundHex = settings.terminalBackgroundHex
        terminal.applyColors()
        if !settings.autoReconnect { cancelReconnect() }
    }
    func start() {
        guard !started, !closed, !ended else { return }; started = true
        terminal.startProcess(executable: launch.executable, args: launch.arguments,
                              environment: launch.environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory.path)
        if !terminal.process.running {
            ended = true; status = "无法创建终端进程"; launch.cleanup()
        }
    }
    func close(immediately: Bool = false) {
        closed = true
        cancelReconnect()
        recorder.finish()
        if started && !ended { terminal.terminate() }
        ended = true; connected = false; status = "已关闭"
        // Give ProxyJump children a moment to leave before removing their config.
        let launch = launch
        if immediately { launch.cleanup() }
        else { Task { try? await Task.sleep(for: .seconds(2)); launch.cleanup() } }
    }
    func cancelReconnect() {
        retryTask?.cancel(); retryTask = nil
        if reconnecting { status = "自动重连已停止" }
        reconnecting = false
    }
    func reconnect(manual: Bool = true) {
        guard !closed, ended, let makeLaunch else { return }
        cancelReconnect()
        if manual { retry.reset() }
        do {
            launch = try makeLaunch()
            // Each transport gets a fresh PTY to prevent late callbacks from a previous process.
            terminal.processDelegate = nil
            terminal = RecordingTerminalView(frame: terminal.frame)
            recorder = InteractionRecorder(token: launch.token, hostID: host?.id, hostName: title, sessionID: id)
            configureTerminal()
            started = false; ended = false; shell = ""; readyAt = nil; profile = nil
            status = manual ? "正在重新连接" : "正在自动重连（第 \(retry.attempts) 次）"
            onLifecycle?("Reconnecting, attempt \(retry.attempts)")
            start()
        } catch {
            status = error.localizedDescription
            onExit?(status)
        }
    }
    func send(_ command: String, execute: Bool = false) {
        guard !ended else { return }
        terminal.send(source: terminal, data: Array((command + (execute ? "\r" : "")).utf8)[...])
        terminal.window?.makeFirstResponder(terminal)
    }
    func snapshot() -> Interaction {
        let shebang = host.map(\.shell).flatMap { $0.isEmpty ? nil : "#!\($0)" } ?? (shell.isEmpty ? "未知 shell" : shell)
        return Interaction(hostID: host?.id, hostName: title, sessionID: id, shell: shebang,
                           command: "手动终端快照", output: InteractionRecorder.clean(String(decoding: recorder.recentOutput, as: UTF8.self)))
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal, !ended, !closed else { return }
        // SwiftTerm 1.13 exposes waitpid's status on macOS, rather than WEXITSTATUS.
        let code = exitCode.map { ($0 & 0x7f) == 0 ? ($0 >> 8) & 0xff : 128 + ($0 & 0x7f) }
        recorder.finish(exitCode: code == 255 ? nil : code.map(Int.init))
        connected = false; ended = true
        status = code == 0 ? "会话已结束" : "连接中断（\(code.map(String.init) ?? "未知")）"
        let diagnostic = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if code != 0, !diagnostic.isEmpty { terminal.feed(text: "\r\n" + diagnostic.suffix(8192).replacingOccurrences(of: "\n", with: "\r\n")) }
        onExit?("SSH process exited with status \(code.map(String.init) ?? "unknown")"); launch.cleanup()
        if let readyAt, Date().timeIntervalSince(readyAt) >= 30 { retry.reset() }
        // Authentication diagnostics only apply before shell readiness. Remote command output
        // may itself contain "permission denied" and must not suppress a later network retry.
        let output = readyAt == nil ? diagnostic + String(decoding: recorder.recentOutput.suffix(8192), as: UTF8.self) : ""
        if host != nil, let delay = retry.nextDelay(exitCode: code.map(Int.init), output: output, enabled: settings.autoReconnect) {
            reconnecting = true
            status += " · \(delay) 秒后重试（\(retry.attempts)/5）"
            onLifecycle?("Retry \(retry.attempts)/5 in \(delay)s")
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.reconnect(manual: false)
            }
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    func makeNSView(context: Context) -> RecordingTerminalView {
        DispatchQueue.main.async { session.start(); session.terminal.window?.makeFirstResponder(session.terminal) }
        return session.terminal
    }
    func updateNSView(_ view: RecordingTerminalView, context: Context) {}
}

struct TerminalPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var showInteractions = true
    @State private var showLog = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in pane(width: geometry.size.width) }
    }
    private func pane(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(session.connected ? Color.mint : session.ended ? .gray : .orange).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title + " · " + session.status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let host = session.host, model.splitSession == nil {
                        Text("\(host.username)@\(host.address):\(String(host.port))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Menu {
                    ForEach(model.snippets) { snippet in Button(snippet.name) { session.send(snippet.command) } }
                    if model.snippets.isEmpty { Text("请先添加快捷命令") }
                } label: { Image(systemName: "curlybraces") }
                .menuStyle(.borderlessButton).fixedSize().disabled(session.ended).help("快捷命令")
                Button { model.pin(session.recent.first ?? session.snapshot()) } label: { Image(systemName: "pin") }.help("收藏交互")
                Button { showInteractions.toggle() } label: { Image(systemName: "sidebar.right") }
                    .disabled(width < 760)
                    .help(width < 760 ? "放宽终端窗格以显示交互记录" : "显示交互记录")
                if session.logURL != nil {
                    Button { showLog = true } label: { Image(systemName: "doc.text") }.help("原始 SSH 日志")
                }
                if session.reconnecting {
                    Button("停止重试") { session.cancelReconnect() }
                }
                if session.ended, session.host != nil {
                    Button("重新连接") { session.reconnect() }.buttonStyle(.borderedProminent)
                }
            }.padding(12).background(.bar)
            HStack(spacing: 0) {
                TerminalSurface(session: session).id(ObjectIdentifier(session.terminal))
                if showInteractions && width >= 760 {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("本次交互").font(.headline); Spacer(); Text("\(session.recent.count)").foregroundStyle(.secondary) }
                        Text("点击图钉保存完整交互，可在收藏中对比。").font(.caption).foregroundStyle(.secondary)
                        if session.recent.isEmpty {
                            Spacer()
                            Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                            Text(session.shell == "other" ? "当前 shell 不支持自动记录，可手动收藏快照。" : "执行命令后，记录会显示在这里。")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            Spacer()
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 10) {
                                    ForEach(session.recent) { item in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Text(item.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                                                Spacer()
                                                Button { model.pin(item) } label: { Image(systemName: "pin") }.buttonStyle(.plain).help("收藏这次交互")
                                            }
                                            Text(item.command).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                                            HStack {
                                                Text(item.exitCode.map { "退出 \($0)" } ?? "未完成")
                                                    .foregroundStyle(item.exitCode == 0 ? .green : .orange)
                                                Spacer()
                                                Button("填入终端") { session.send(item.command) }.disabled(session.ended)
                                            }.font(.caption2)
                                        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                    }.padding(16).frame(width: 250).background(Color(nsColor: .controlBackgroundColor))
                }
            }
            HStack {
                Text("⌃C 中断 · ⌘K 清屏 · ⌘C 复制 · ⌘V 粘贴 · Tab 补全 · ↑ 历史").lineLimit(1)
                Spacer()
                Text(session.shell.isEmpty ? "等待认证" : session.shell)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showInteractions)
            .sheet(isPresented: $showLog) {
                if let url = session.logURL { RawSSHLogView(url: url) }
            }
            .onAppear { if model.splitSession != nil { showInteractions = false } }
            .onChange(of: model.splitSession) { _, value in if value != nil { showInteractions = false } }
            .overlay {
                if model.splitSession != nil {
                    Rectangle().stroke(model.commandSession?.id == session.id ? sea.opacity(0.6) : .clear, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}
