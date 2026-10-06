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
        guard let recorder else { super.dataReceived(slice: slice); return }
        let bytes = recorder.feed(slice)
        if !bytes.isEmpty { super.dataReceived(slice: bytes[...]) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    func applyColors() {
        let dark = theme == "dark" || (theme == "system" && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let background = TerminalAppearance.background(hex: backgroundHex, dark: dark)
        let foreground = TerminalAppearance.foreground(on: background)
        if nativeBackgroundColor != background { nativeBackgroundColor = background }
        if nativeForegroundColor != foreground { nativeForegroundColor = foreground }
        if caretColor != foreground { caretColor = foreground }
    }
    func clearScreen() {
        // Feed display controls locally, leaving the remote shell and command recorder untouched.
        feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    @Published private(set) var host: Host?
    private var launch: SSHLaunch
    let directory: URL
    @Published private(set) var terminal: RecordingTerminalView
    private var recorder: InteractionRecorder
    @Published var status = L10n.tr("Connecting")
    @Published var connected = false
    @Published var ended = false
    @Published var recent: [Interaction] = []
    @Published var shell = ""
    @Published private(set) var reconnecting = false
    var onInteraction: ((Interaction) -> Void)?
    var onExit: ((String) -> Void)?
    var onCompletion: (() -> Void)?
    var onLifecycle: ((String) -> Void)?
    var onReady: ((SystemProfile?) -> Void)?
    var onFocus: (() -> Void)?
    private var profile: SystemProfile?
    var logURL: URL? { launch.logURL }
    var diagnosticsDirectory: URL?
    @Published private(set) var diagnosticURL: URL?
    var makeLaunch: (() throws -> SSHLaunch)?
    private var settings: AppSettings
    private var fontSizeOverride: Double?
    private var retry = ReconnectPolicy()
    private var retryTask: Task<Void, Never>?
    private var readyAt: Date?
    private var attemptStartedAt = Date()
    private var closed = false
    private var started = false
    var title: String { host?.name ?? L10n.tr("Local Terminal") }
    var displayName: HostDisplayName { host?.displayName ?? HostDisplayName(name: title, hostname: nil) }
    init(host: Host?, launch: SSHLaunch, settings: AppSettings, directory: URL) {
        self.host = host; self.launch = launch; self.directory = directory; self.settings = settings
        terminal = RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        recorder = InteractionRecorder(token: launch.token, hostID: host?.id, hostName: host?.name ?? L10n.tr("Local Terminal"),
                                       sessionID: id, hostname: host?.displayName.hostname)
        super.init()
        configureTerminal()
    }
    private func configureTerminal() {
        terminal.recorder = recorder
        terminal.processDelegate = self
        terminal.onFocus = { [weak self] in self?.onFocus?() }
        terminal.onFontSizeChange = { [weak self] in self?.changeFontSize(by: $0) }
        apply(settings)
        terminal.optionAsMetaKey = true
        terminal.setAccessibilityLabel(L10n.tr("Interactive terminal"))
        recorder.onReady = { [weak self] shell in
            guard let self else { return }
            self.shell = shell; status = L10n.tr("Connected"); connected = true
            reconnecting = false; readyAt = Date()
            onLifecycle?("Shell ready: \(shell)")
            onReady?(profile)
        }
        recorder.onSystemProfile = { [weak self] profile in
            self?.profile = profile
            self?.host?.systemProfile = profile
        }
        recorder.onInteraction = { [weak self] interaction in
            guard let self else { return }
            recent.insert(interaction, at: 0)
            if recent.count > 100 { recent.removeLast(recent.count - 100) }
            onInteraction?(interaction)
        }
    }
    func apply(_ settings: AppSettings) {
        if self.settings.fontSize != settings.fontSize { fontSizeOverride = nil }
        self.settings = settings
        applyFont()
        terminal.theme = settings.appearance
        terminal.backgroundHex = settings.terminalBackgroundHex
        terminal.applyColors()
        if !settings.autoReconnect { cancelReconnect() }
    }
    func changeFontSize(by delta: Double) {
        fontSizeOverride = min(36, max(10, (fontSizeOverride ?? settings.fontSize) + delta))
        applyFont()
    }
    private func applyFont() {
        var appearance = settings
        appearance.fontSize = fontSizeOverride ?? settings.fontSize
        let font = TerminalAppearance.font(appearance)
        if terminal.font != font { terminal.font = font }
    }
    func start() {
        guard !started, !closed, !ended else { return }; started = true
        attemptStartedAt = Date()
        terminal.startProcess(executable: launch.executable, args: launch.arguments,
                              environment: launch.environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory.path)
        if !terminal.process.running {
            ended = true; status = L10n.tr("Could not start terminal process")
            saveDiagnostic(reason: "launch_failed", waitStatus: nil)
            onExit?(status); launch.cleanup()
        }
    }
    func close(immediately: Bool = false) {
        closed = true
        cancelReconnect()
        recorder.finish()
        if started && !ended { terminal.terminate() }
        ended = true; connected = false; status = L10n.tr("Closed")
        // Give ProxyJump children a moment to leave before removing their config.
        let launch = launch
        if immediately { launch.cleanup() }
        else { Task { try? await Task.sleep(for: .seconds(2)); launch.cleanup() } }
    }
    func cancelReconnect() {
        retryTask?.cancel(); retryTask = nil
        if reconnecting { status = L10n.tr("Automatic reconnection stopped") }
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
            recorder = InteractionRecorder(token: launch.token, hostID: host?.id, hostName: title,
                                           sessionID: id, hostname: host?.displayName.hostname)
            configureTerminal()
            started = false; ended = false; shell = ""; readyAt = nil; profile = nil
            status = manual ? L10n.tr("Reconnecting") : L10n.tr("Reconnecting automatically (attempt \(retry.attempts))")
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
        let shebang = host.map(\.shell).flatMap { $0.isEmpty ? nil : "#!\($0)" } ?? (shell.isEmpty ? L10n.tr("Unknown shell") : shell)
        return Interaction(hostID: host?.id, hostName: title, sessionID: id, shell: shebang,
                           command: L10n.tr("Manual terminal snapshot"), output: InteractionRecorder.clean(String(decoding: recorder.recentOutput, as: UTF8.self)),
                           hostname: host?.displayName.hostname)
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal, !ended, !closed else { return }
        // SwiftTerm 1.13 exposes waitpid's status on macOS, rather than WEXITSTATUS.
        let code = TerminalDiagnostic.exitCode(exitCode)
        recorder.finish(exitCode: recorder.shellExitCode ?? (code == 255 ? nil : code))
        connected = false; ended = true
        // A wrapper completion marker also occurs when the child shell crashes. Preserve
        // every nonzero/unknown exit; only successful completion can close its pane.
        let completed = code == 0 && (recorder.shellExitCode == nil || recorder.shellExitCode == 0)
        status = completed ? L10n.tr("Session ended") : L10n.tr("Session ended unexpectedly (\(code.map(String.init) ?? L10n.tr("Unknown")))")
        let diagnostic = TerminalDiagnostic.tail(of: logURL)
        if !completed {
            saveDiagnostic(reason: recorder.shellExitCode == nil ? "transport_or_process_failure" : "shell_nonzero_exit",
                           waitStatus: exitCode)
            if !diagnostic.isEmpty { terminal.feed(text: "\r\n" + diagnostic.suffix(8192).replacingOccurrences(of: "\n", with: "\r\n")) }
        }
        onExit?("SSH process exited with status \(code.map(String.init) ?? "unknown")\(diagnosticURL.map { "; context: \($0.lastPathComponent)" } ?? "")")
        launch.cleanup()
        if completed {
            cancelReconnect()
            onCompletion?()
            return
        }
        if let readyAt, Date().timeIntervalSince(readyAt) >= 30 { retry.reset() }
        // Authentication diagnostics only apply before shell readiness. Remote command output
        // may itself contain "permission denied" and must not suppress a later network retry.
        let output = readyAt == nil ? diagnostic + String(decoding: recorder.recentOutput.suffix(8192), as: UTF8.self) : ""
        // A shell's explicit 255 (or crash) is not a transport failure to retry.
        if host != nil, recorder.shellExitCode == nil,
           let delay = retry.nextDelay(exitCode: code, output: output, enabled: settings.autoReconnect) {
            reconnecting = true
            status += L10n.tr(" · Retrying in \(delay)s (\(retry.attempts)/5)")
            onLifecycle?("Retry \(retry.attempts)/5 in \(delay)s")
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.reconnect(manual: false)
            }
        } else if host != nil, settings.autoReconnect, retry.exhausted {
            status += L10n.tr(" · Retry limit reached. Reconnect manually.")
        }
    }
    private func saveDiagnostic(reason: String, waitStatus: Int32?) {
        guard let destination = diagnosticsDirectory ?? logURL?.deletingLastPathComponent() else { return }
        let diagnostic = TerminalDiagnostic(
            sessionID: id, connectionID: launch.token, hostID: host?.id, hostName: title,
            shell: shell.isEmpty ? (host?.shell ?? "") : shell, reason: reason, waitStatus: waitStatus,
            shellExitCode: recorder.shellExitCode, connectedSeconds: readyAt.map { Date().timeIntervalSince($0) },
            columns: terminal.getTerminal().cols, rows: terminal.getTerminal().rows,
            terminalTail: InteractionRecorder.clean(String(decoding: recorder.recentOutput, as: UTF8.self)),
            sshTail: TerminalDiagnostic.tail(of: logURL),
            interactions: recent.filter { $0.date >= attemptStartedAt }, secrets: [host?.password ?? ""])
        do {
            diagnosticURL = try diagnostic.save(in: destination)
            status += L10n.tr(" · Exit context saved")
        } catch {
            status += L10n.tr(" · Could not save context: \(error.localizedDescription)")
            onLifecycle?("Terminal context write failed: \(error.localizedDescription)")
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// SwiftUI may size a representable to zero while mounting or removing it.
/// Keep those transient sizes away from the emulator: reflowing to two columns
/// can exhaust scrollback before the real pane dimensions arrive.
final class TerminalContainerView: NSView {
    let terminal: RecordingTerminalView

    init(terminal: RecordingTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard terminal.superview === self, bounds.width > 0, bounds.height > 0 else { return }
        if terminal.frame != bounds { terminal.frame = bounds }
    }

    func detach() {
        // SwiftUI can dismantle the old host after a split has already reparented
        // this terminal into its new host.
        if terminal.superview === self { terminal.removeFromSuperview() }
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    func makeNSView(context: Context) -> TerminalContainerView {
        let view = TerminalContainerView(terminal: session.terminal)
        DispatchQueue.main.async { [weak session, weak view] in
            guard let session, let view, let window = view.window,
                  view.terminal.superview === view, session.terminal === view.terminal else { return }
            view.layoutSubtreeIfNeeded()
            session.start()
            window.makeFirstResponder(view.terminal)
        }
        return view
    }
    func updateNSView(_ view: TerminalContainerView, context: Context) {}
    static func dismantleNSView(_ view: TerminalContainerView, coordinator: ()) {
        view.detach()
    }
}

private struct TerminalHeaderIdentity: View {
    let name: HostDisplayName
    let host: Host?
    let folder: String?

    var body: some View {
        if let host, let folder {
            ViewThatFits(in: .horizontal) {
                fixedRow(name.full, host: host, folder: folder)
                fixedRow(name.compact, host: host, folder: folder)
                adaptiveRow(host: host, folder: folder)
            }
            .help("\(name.full) · \(endpoint(host)) · \(folder)")
            .accessibilityLabel("\(name.full)，\(endpoint(host))，\(folder)")
        } else {
            HostNameLabel(name).font(.system(size: 12, weight: .medium))
        }
    }

    private func fixedRow(_ title: String, host: Host, folder: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).fixedSize()
            separator
            Text(endpoint(host)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
            separator
            Text(folder).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func adaptiveRow(host: Host, folder: String) -> some View {
        HStack(spacing: 6) {
            HostNameLabel(name)
                .font(.system(size: 12, weight: .medium))
                .layoutPriority(3)
            separator
            Text(endpoint(host))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 56, alignment: .leading)
                .layoutPriority(2)
            separator
            Text(folder)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 56, alignment: .leading)
                .layoutPriority(1)
        }
        .lineLimit(1)
    }

    private var separator: some View { Text("·").foregroundStyle(.tertiary) }
    private func endpoint(_ host: Host) -> String { "\(host.username)@\(host.address):\(host.port)" }
}

struct TerminalPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var showInteractions = true
    @State private var showLog = false
    @State private var showDiagnostic = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in pane(width: geometry.size.width) }
    }
    private func pane(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(session.connected ? Color.mint : session.ended ? .gray : .orange).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    let folder = session.host.map { host in
                        model.hosts.first { $0.id == host.id }?.folderPath ?? host.folderPath
                    }
                    TerminalHeaderIdentity(name: session.displayName, host: session.host, folder: folder)
                    .lineLimit(1)
                    .accessibilityIdentifier("terminal-header-identity")
                    Text(session.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(session.status)
                        .accessibilityIdentifier("terminal-header-status")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    ForEach(model.snippets) { snippet in Button(snippet.name) { session.send(snippet.command) } }
                    if model.snippets.isEmpty { Text(L10n.tr("Add a snippet first")) }
                } label: { Image(systemName: "curlybraces") }
                .menuStyle(.borderlessButton).fixedSize().disabled(session.ended).help(L10n.tr("Snippets"))
                Button { model.pin(session.recent.first ?? session.snapshot()) } label: { Image(systemName: "pin") }.help(L10n.tr("Pin Interaction"))
                Button { showInteractions.toggle() } label: { Image(systemName: "sidebar.right") }
                    .disabled(width < 760)
                    .help(width < 760 ? L10n.tr("Widen the terminal pane to show interactions") : L10n.tr("Show interactions"))
                if session.logURL != nil {
                    Button { showLog = true } label: { Image(systemName: "doc.text") }.help(L10n.tr("Raw SSH Log"))
                }
                if session.diagnosticURL != nil {
                    Button { showDiagnostic = true } label: { Image(systemName: "exclamationmark.bubble") }.help(L10n.tr("Exit Context"))
                }
                if session.reconnecting {
                    Button(L10n.tr("Stop Retrying")) { session.cancelReconnect() }
                }
                if session.ended, session.host != nil {
                    Button(L10n.tr("Reconnect")) { session.reconnect() }.buttonStyle(.borderedProminent)
                }
            }.padding(12).background(.bar)
            HStack(spacing: 0) {
                TerminalSurface(session: session).id(ObjectIdentifier(session.terminal))
                if showInteractions && width >= 760 {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(L10n.tr("Interactions")).font(.headline); Spacer(); Text("\(session.recent.count)").foregroundStyle(.secondary) }
                        Text(L10n.tr("Pin an interaction to save it and compare it in Pins.")).font(.caption).foregroundStyle(.secondary)
                        if session.recent.isEmpty {
                            Spacer()
                            Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                            Text(session.shell == "other" ? L10n.tr("This shell does not support automatic recording. You can pin a manual snapshot.") : L10n.tr("Recorded interactions will appear here after you run a command."))
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
                                                Button { model.pin(item) } label: { Image(systemName: "pin") }.buttonStyle(.plain).help(L10n.tr("Pin This Interaction"))
                                            }
                                            Text(item.command).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                                            HStack {
                                                let exitLabel: String = item.exitCode.map { L10n.tr("Exit \($0)") } ?? L10n.tr("Incomplete")
                                                Text(exitLabel)
                                                    .foregroundStyle(item.exitCode == 0 ? .green : .orange)
                                                Spacer()
                                                Button(L10n.tr("Insert into Terminal")) { session.send(item.command) }.disabled(session.ended)
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
                Text(L10n.tr("⌃C Interrupt · ⌘K Clear · ⌘−/⌘= Font size · ⌘C Copy · ⌘V Paste · Tab Complete · ↑ History")).lineLimit(1)
                Spacer()
                Text(session.shell.isEmpty ? L10n.tr("Waiting for authentication") : session.shell)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showInteractions)
            .sheet(isPresented: $showLog) {
                if let url = session.logURL { RawSSHLogView(url: url) }
            }
            .sheet(isPresented: $showDiagnostic) {
                if let url = session.diagnosticURL { RawSSHLogView(url: url, title: L10n.tr("Exit Context")) }
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
