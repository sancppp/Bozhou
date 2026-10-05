import SwiftUI
import BozhouCore

let sea = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.40, green: 0.77, blue: 0.92, alpha: 1)
        : NSColor(srgbRed: 0.07, green: 0.34, blue: 0.52, alpha: 1)
})
let canvas = Color(nsColor: .underPageBackgroundColor)

struct BrandMark: View {
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(LinearGradient(colors: [sea, Color(red: 0.035, green: 0.15, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sailboat.fill").font(.system(size: size * 0.54, weight: .medium)).foregroundStyle(Color(red: 0.43, green: 0.95, blue: 0.80))
        }.frame(width: size, height: size)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            if let session = model.active {
                if let other = model.sessions.first(where: { $0.id == model.splitSession && $0.id != session.id }) {
                    if model.splitVertical {
                        VSplitView {
                            TerminalPane(session: session).frame(minHeight: 180)
                            TerminalPane(session: other).frame(minHeight: 180)
                        }
                    } else {
                        HSplitView {
                            TerminalPane(session: session).frame(minWidth: 440)
                            TerminalPane(session: other).frame(minWidth: 440)
                        }
                    }
                } else { TerminalPane(session: session) }
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    Group {
                        switch model.page {
                        case .hosts: HostsPage()
                        case .identities: IdentitiesPage()
                        case .snippets: SnippetsPage()
                        case .pins: PinsPage()
                        case .history: HistoryPage()
                        case .knownHosts: KnownHostsPage()
                        case .logs: LogsPage()
                        case .settings: PreferencesView()
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 580).background(canvas).tint(sea).preferredColorScheme(model.colorScheme)
        .toolbar { titlebar }
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("BozhouCredentialsChanged"))) { _ in
            model.perform { try model.reload() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.sessions.count)
        .sheet(item: $model.editorHost) { HostEditor(host: $0).environmentObject(model) }
        .sheet(item: $model.sftpHost) { SFTPView(host: $0).environmentObject(model) }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 11).background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 3).padding(.bottom, 22).allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toast)
    }
    @ToolbarContentBuilder
    private var titlebar: some ToolbarContent {
        ToolbarItem(id: "workspace", placement: .navigation) {
            Button { model.activeSession = nil; model.splitSession = nil } label: {
                HStack(spacing: 7) { BrandMark(size: 20); Text("泊舟").font(.system(size: 13, weight: .semibold)) }
                    .padding(.horizontal, 10).frame(height: 32, alignment: .center)
                    .background(model.activeSession == nil ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("泊舟，返回工作空间").help("返回工作空间")
        }.flatToolbarItem()
        ToolbarItemGroup(placement: .navigation) {
            ForEach(model.sessions) { session in
                sessionTab(session)
            }
        }.flatToolbarItem()
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
        }
        ToolbarItem(id: "sessions", placement: .primaryAction) {
            if model.sessions.count > 2 {
                Menu {
                    ForEach(model.sessions) { session in
                        Button(session.title) { model.activeSession = session.id; model.splitSession = nil }
                    }
                } label: { Label("所有会话", systemImage: "rectangle.stack").frame(height: 32) }
                    .menuStyle(.borderlessButton).help("切换会话")
            }
        }.flatToolbarItem()
        ToolbarItem(id: "split", placement: .primaryAction) {
            if let active = model.active {
                Menu {
                    ForEach([false, true], id: \.self) { vertical in
                        Menu(vertical ? "上下分屏" : "左右分屏") {
                            Button("新建本地终端") { split(vertical: vertical) { model.localTerminal() } }
                            if let host = active.host { Button("新建当前主机连接") { split(vertical: vertical) { model.connect(host) } } }
                            ForEach(model.sessions.filter { $0.id != active.id }) { other in
                                Button(other.title) { model.splitVertical = vertical; model.splitSession = other.id }
                            }
                        }
                    }
                    if model.splitSession != nil { Button("取消分屏") { model.splitSession = nil } }
                } label: { Label("分屏", systemImage: "rectangle.split.2x1").frame(height: 32) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }.flatToolbarItem()
        ToolbarItem(id: "new", placement: .primaryAction) {
            Menu {
                Button("新建主机") { model.editorHost = Host() }
                Button("本地终端") { model.localTerminal() }
            } label: { Image(systemName: "plus").frame(width: 26, height: 32).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).fixedSize().help("新建")
        }.flatToolbarItem()
    }
    private func sessionTab(_ session: TerminalSession) -> some View {
        HStack(spacing: 0) {
            Button { model.activeSession = session.id; model.splitSession = nil } label: {
                Label(session.title, systemImage: "terminal").labelStyle(.titleAndIcon).lineLimit(1)
                    .frame(minWidth: 72, maxWidth: 150).padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).help(session.title)
            Button { model.closeSession(session.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).help("关闭 \(session.title)")
        }
        .font(.system(size: 12))
        .background(model.activeSession == session.id || model.splitSession == session.id ? Color.primary.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
    private func split(vertical: Bool, create: () -> Void) {
        let original = model.activeSession
        create()
        if model.activeSession != original {
            model.splitSession = model.activeSession; model.activeSession = original; model.splitVertical = vertical
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("工作空间").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(10)
            ForEach(Page.allCases) { page in
                if page == .settings { Spacer() }
                Button { model.page = page } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                        Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                        Spacer()
                        if page == .hosts { Text("\(model.hosts.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        if page == .pins && !model.pins.isEmpty { Text("\(model.pins.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(model.page == page ? sea : Color.primary.opacity(0.75))
                        .background(model.page == page ? sea.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(8).frame(width: 160).background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func flatToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(sea.opacity(0.7))
                .frame(width: 84, height: 84).background(sea.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            action().padding(.top, 8)
        }.padding(30)
    }
}

struct PageHeader: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 25, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
