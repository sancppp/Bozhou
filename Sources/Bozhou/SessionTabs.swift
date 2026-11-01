import SwiftUI
import BozhouCore

struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.onWidth = { width = $0 }
    }
    final class Observer: NSView {
        var onWidth: ((CGFloat) -> Void)?
        private var resizeObserver: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            guard let window else { return }
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.reportWidth()
            }
            reportWidth()
        }
        private func reportWidth() {
            guard let width = window?.frame.width else { return }
            DispatchQueue.main.async { [weak self] in self?.onWidth?(width) }
        }
        deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }
    }
}

struct SessionMenuButton: View {
    @ObservedObject var session: TerminalSession
    var action: () -> Void
    var body: some View { Button(session.tabDisplayName.full, action: action) }
}

struct SessionTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: TerminalSession
    var showsIcon = true
    var onRename: (TerminalSession) -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button { model.activeSession = session.id; model.splitSession = nil } label: {
                HStack(spacing: 5) {
                    if showsIcon { Image(systemName: "terminal").foregroundStyle(session.ended ? .secondary : sea) }
                    HostNameLabel(session.tabDisplayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).help(session.tabDisplayName.full)
                .accessibilityIdentifier("session-tab-" + session.id.uuidString)
            Button { model.closeSession(session.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.tr("Close \(session.tabDisplayName.full)"))
        }
        .font(.system(size: 12))
        .background(model.activeSession == session.id || model.splitSession == session.id ? sea.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button(L10n.tr("Rename Tab…")) { onRename(session) }
            if session.customTabName != nil { Button(L10n.tr("Reset Tab Name")) { session.renameTab("") } }
            Divider()
            Button(L10n.tr("Close Current Session")) { model.closeSession(session.id) }
        }
    }
}

struct HorizontalSessionTabs: View {
    @EnvironmentObject var model: AppModel
    let width: CGFloat
    var onRename: (TerminalSession) -> Void
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.sessions) { session in
                            SizedSessionTab(session: session, availableWidth: geometry.size.width, count: model.sessions.count, onRename: onRename)
                                .id(session.id)
                        }
                    }
                }.scrollIndicators(.hidden)
                    .task(id: "\(model.activeSession?.uuidString ?? "")-\(model.sessions.count)-\(geometry.size.width)") {
                        // SwiftUI must lay out the newly inserted/resized tab before revealing it.
                        await Task.yield()
                        if let id = model.activeSession { reader.scrollTo(id, anchor: .trailing) }
                    }
            }
        }.frame(minWidth: 160, idealWidth: width, maxWidth: width).frame(height: 34)
    }
}

private struct SizedSessionTab: View {
    @ObservedObject var session: TerminalSession
    let availableWidth: CGFloat
    let count: Int
    var onRename: (TerminalSession) -> Void
    var body: some View {
        // The fixed suffix has priority over the user label, even for wide Unicode hostnames.
        let suffixWidth = (session.tabDisplayName.suffix(compact: true) as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        let minimum = max(112, ceil(suffixWidth) + 80)
        let width = max(minimum, min(264, (availableWidth - CGFloat(max(0, count - 1)) * 4) / CGFloat(max(1, count))))
        SessionTab(session: session, showsIcon: width >= 180, onRename: onRename).frame(width: width)
    }
}

struct TabNameEditor: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    init(session: TerminalSession) {
        self.session = session
        _name = State(initialValue: session.customTabName ?? session.title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("Rename Tab…")).font(.title2)
            TextField(L10n.tr("Tab name"), text: $name)
            Text(L10n.tr("This name applies to this session. The hostname stays visible."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Reset Tab Name")) { session.renameTab(""); dismiss() }
                Spacer()
                Button(L10n.tr("Save")) { session.renameTab(name); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 460)
    }
}
