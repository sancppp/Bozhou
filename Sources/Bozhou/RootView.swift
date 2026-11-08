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
    @State private var contentWidth: CGFloat = 1100
    @State private var renamingSession: TerminalSession?
    private var verticalTabs: Bool { model.settings.tabPlacement == .vertical }
    var body: some View {
        HStack(spacing: 0) {
            if verticalTabs || model.active == nil {
                sidebar
                Divider()
            }
            workspace
        }
        .background(WindowWidthReader(width: $contentWidth))
        .background(UpdatePresentation(updater: model.updater))
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
        .sheet(item: $renamingSession) { TabNameEditor(session: $0) }
        .alert(L10n.tr("Operation incomplete"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.tr("OK"), role: .cancel) { model.error = nil }
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
    private var workspace: some View {
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
                            TerminalPane(session: session).frame(minWidth: verticalTabs ? 320 : 440)
                            TerminalPane(session: other).frame(minWidth: verticalTabs ? 320 : 440)
                        }
                    }
                } else { TerminalPane(session: session) }
            } else {
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
    @ToolbarContentBuilder
    private var titlebar: some ToolbarContent {
        ToolbarItem(id: "workspace", placement: .navigation) {
            Button { model.showWorkspace() } label: {
                HStack(spacing: 7) { BrandMark(size: 20); Text(L10n.tr("Bozhou")).font(.system(size: 13, weight: .semibold)) }
                    .padding(.horizontal, 10).frame(height: 32, alignment: .center)
                    .background(model.activeSession == nil ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L10n.tr("Bozhou, return to workspace")).help(L10n.tr("Return to workspace"))
        }.flatToolbarItem()
        // Recreate the native item on resize: NSToolbar caches a hosting item's size limits.
        ToolbarItem(id: "tabs-\(Int(contentWidth))", placement: .navigation) {
            if !verticalTabs && !model.sessions.isEmpty {
                HorizontalSessionTabs(width: max(160, contentWidth - 400), onRename: { renamingSession = $0 })
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
                        SessionMenuButton(session: session) { model.selectSession(session.id) }
                    }
                } label: { Label(L10n.tr("All Sessions"), systemImage: "rectangle.stack").frame(height: 32) }
                    .menuStyle(.borderlessButton).help(L10n.tr("Switch session"))
            }
        }.flatToolbarItem()
        ToolbarItem(id: "tab-layout", placement: .primaryAction) {
            Menu {
                Picker(L10n.tr("Tab Bar"), selection: Binding(get: { model.settings.tabPlacement }, set: { model.setTabPlacement($0) })) {
                    ForEach(SessionTabPlacement.allCases) { Text($0.title).tag($0) }
                }
                if let session = model.active {
                    Button(L10n.tr("Rename Tab…")) { renamingSession = session }
                }
            } label: { Image(systemName: verticalTabs ? "sidebar.left" : "rectangle.topthird.inset.filled").frame(width: 26, height: 32) }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("Tab Bar"))
        }.flatToolbarItem()
        ToolbarItem(id: "new", placement: .primaryAction) {
            Menu {
                Button(L10n.tr("New Host")) { model.editorHost = Host() }
                Button(L10n.tr("Local Terminal")) { model.localTerminal() }
            } label: { Image(systemName: "plus").frame(width: 26, height: 32).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("New"))
        }.flatToolbarItem()
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.tr("Workspace")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(10)
            ForEach(Page.allCases.filter { $0 != .settings }) { page in
                pageButton(page)
            }
            if verticalTabs && !model.sessions.isEmpty {
                Divider().padding(.vertical, 6)
                Text(L10n.tr("Sessions")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.sessions) { session in
                                SessionTab(session: session, onRename: { renamingSession = $0 }).id(session.id)
                            }
                        }
                    }.onChange(of: model.activeSession) { _, id in if let id { reader.scrollTo(id) } }
                }
            } else { Spacer() }
            pageButton(.settings)
        }.padding(8).frame(width: verticalTabs ? 220 : 175).background(Color(nsColor: .windowBackgroundColor))
    }
    private func pageButton(_ page: Page) -> some View {
                Button { model.showWorkspace(page) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                        Text(page.title).font(.system(size: 13, weight: model.activeSession == nil && model.page == page ? .semibold : .regular))
                        Spacer()
                        if page == .hosts { Text("\(model.hosts.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        if page == .pins && !model.pins.isEmpty { Text("\(model.pins.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(model.activeSession == nil && model.page == page ? sea : Color.primary.opacity(0.75))
                        .background(model.activeSession == nil && model.page == page ? sea.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
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
