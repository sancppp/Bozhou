import SwiftUI
import UniformTypeIdentifiers
import BozhouCore

struct IdentitiesPage: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Identity?
    @State private var deleting: Identity?
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                PageHeader(title: L10n.tr("Keys"), detail: L10n.tr("Organize your keys. Private keys stay in the locations you choose."))
                Button { importKey() } label: { Label(L10n.tr("Import Key"), systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(importing)
            }
            if model.identities.isEmpty {
                EmptyState(symbol: "key.horizontal", title: L10n.tr("Your Connection Credentials"), detail: L10n.tr("Import a private key, or select a public key to match its private key in the same directory.")) {
                    Button(L10n.tr("Choose Key File")) { importKey() }.disabled(importing)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.identities) { key in
                    HStack(spacing: 16) {
                        Image(systemName: "key.fill").foregroundStyle(sea).font(.title2).frame(width: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(key.name).font(.headline)
                            Text(key.privateKeyPath.isEmpty ? L10n.tr("Public key only · Authenticate with SSH Agent or the associated local private key") : key.privateKeyPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            if !key.fingerprint.isEmpty { Text(key.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        Button(L10n.tr("Public Key")) { selected = key }
                        Button { deleting = key } label: { Image(systemName: "trash") }.help(L10n.tr("Remove key record"))
                    }.padding(.vertical, 12)
                }.scrollContentBackground(.hidden)
            }
        }.padding(28)
        .sheet(item: $selected) { key in
            VStack(alignment: .leading, spacing: 18) {
                Text(key.name).font(.title2)
                Text(key.publicKey.isEmpty ? L10n.tr("No matching .pub file found. Use ssh-keygen -y to export the public key from the private key.") : key.publicKey)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    if !key.publicKey.isEmpty { Button(L10n.tr("Copy Public Key")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.publicKey, forType: .string) } }
                    Spacer(); Button(L10n.tr("Done")) { selected = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 560)
        }
        .alert(L10n.tr("Remove Key Record?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Remove"), role: .destructive) {
                guard let deleting else { return }
                model.perform {
                    guard !model.hosts.contains(where: { $0.identityID == deleting.id }) else { throw BozhouError.invalid(L10n.tr("This key is still used by a host. Change its authentication settings first.")) }
                    try model.store.delete(Identity.self, id: deleting.id); try model.reload()
                }
                self.deleting = nil
            }
        } message: { Text(L10n.tr("Only the app record will be removed. The key file will remain.")) }
    }
    private func importKey() {
        let panel = NSOpenPanel(); panel.title = L10n.tr("Choose an SSH Private or Public Key"); panel.message = L10n.tr("You can import just a public key. If its private key exists in the same directory, its path will be saved."); panel.prompt = L10n.tr("Import")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let candidate = url.path.hasSuffix(".pub") ? String(url.path.dropLast(4)) : url.path
        let privatePath = FileManager.default.isReadableFile(atPath: candidate) ? candidate : ""
        importing = true
        Task {
            let key = await Task.detached {
                let pub = (try? String(contentsOf: url.path.hasSuffix(".pub") ? url : URL(fileURLWithPath: privatePath + ".pub"), encoding: .utf8)) ?? ""
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-lf", url.path]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
                var fingerprint = ""
                if (try? process.run()) != nil {
                    fingerprint = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    process.waitUntilExit()
                }
                return Identity(name: URL(fileURLWithPath: candidate).lastPathComponent, privateKeyPath: privatePath, publicKey: pub, fingerprint: fingerprint)
            }.value
            model.perform {
                guard !key.fingerprint.isEmpty else { throw BozhouError.invalid(L10n.tr("Could not recognize the SSH key. Check the selected file.")) }
                if model.identities.contains(where: { $0.fingerprint == key.fingerprint }) { model.notify(L10n.tr("This key has already been imported")); return }
                try model.store.save(key); try model.reload(); model.notify(L10n.tr("Key imported"))
            }
            importing = false
        }
    }
}

struct SnippetsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Snippet?
    @State private var deleting: Snippet?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                PageHeader(title: L10n.tr("Snippets"), detail: L10n.tr("Save common commands and insert them into a terminal. Review before running."))
                Button { editing = Snippet() } label: { Label(L10n.tr("New Snippet"), systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            if model.snippets.isEmpty {
                EmptyState(symbol: "curlybraces", title: L10n.tr("Less Repeated Typing"), detail: L10n.tr("Save deployment checks, log queries and system diagnostics as reusable snippets.")) {
                    Button(L10n.tr("New Snippet")) { editing = Snippet() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.snippets) { snippet in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(snippet.name).font(.headline)
                                    Spacer()
                                    Button(L10n.tr("Edit")) { editing = snippet }
                                    Button { deleting = snippet } label: { Image(systemName: "trash") }
                                }
                                Text(snippet.command).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                if !snippet.detail.isEmpty { Text(snippet.detail).font(.caption).foregroundStyle(.secondary) }
                                if !model.sessions.filter({ !$0.ended }).isEmpty {
                                    Menu(L10n.tr("Insert into Terminal")) {
                                        ForEach(model.sessions.filter { !$0.ended }) { session in
                                            Button(session.displayName.full) { model.activeSession = session.id; session.send(snippet.command) }
                                        }
                                    }.fixedSize()
                                }
                            }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
        }.padding(28)
            .sheet(item: $editing) { snippet in SnippetEditor(snippet: snippet).environmentObject(model) }
            .alert(L10n.tr("Delete Snippet?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("Delete"), role: .destructive) {
                    if let deleting { model.perform { try model.store.delete(Snippet.self, id: deleting.id); try model.reload() } }; deleting = nil
                }
            }
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var snippet: Snippet
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("Snippets")).font(.title2.weight(.semibold))
            TextField(L10n.tr("Name"), text: $snippet.name)
            TextEditor(text: $snippet.command).font(.system(size: 13, design: .monospaced)).frame(height: 150).border(.quaternary)
            TextField(L10n.tr("Description (optional)"), text: $snippet.detail)
            HStack { Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button(L10n.tr("Save")) {
                    model.perform { try model.store.save(snippet); try model.reload(); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty || snippet.command.isEmpty)
            }
        }.padding(28).frame(width: 520)
    }
}

struct InteractionDetail: View {
    @EnvironmentObject var model: AppModel
    let item: Interaction
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { HostNameLabel(model.displayName(for: item)).font(.headline); Spacer(); Text(item.date, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
            HStack { Text(item.shell); Spacer(); Text(item.exitCode.map { L10n.tr("Exit status \($0)") } ?? L10n.tr("Incomplete / Manual snapshot")) }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(item.command).font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            Divider()
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    Text(item.output.isEmpty ? L10n.tr("(No output)") : item.output).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            if item.truncated { Text(L10n.tr("Output exceeded 256 KiB and was truncated")).font(.caption).foregroundStyle(.orange) }
        }.padding(22).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PinsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Set<UUID> = []
    @State private var deleting: Pin?
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: L10n.tr("Pins"), detail: L10n.tr("Save useful interactions. Select two to compare commands and output side by side."))
            if model.pins.isEmpty {
                EmptyState(symbol: "pin", title: L10n.tr("Keep What Matters"), detail: L10n.tr("Click a pin in the terminal sidebar to save the timestamp, command and output.")) { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack {
                        TextField(L10n.tr("Search pins"), text: $search).textFieldStyle(.roundedBorder)
                        List(model.pins.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || model.displayName(for: $0.interaction).full.localizedCaseInsensitiveContains(search) }, selection: $selection) { pin in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(pin.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    HostNameLabel(model.displayName(for: pin.interaction)).font(.caption2).foregroundStyle(.secondary)
                                    Text(L10n.date(pin.interaction.date, abbreviated: true)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button {
                                    if selection.contains(pin.id) { selection.remove(pin.id) }
                                    else if selection.count < 2 { selection.insert(pin.id) }
                                } label: {
                                    Image(systemName: selection.contains(pin.id) ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.plain).help(L10n.tr("Add to or remove from comparison")).accessibilityLabel(L10n.tr("Compare: \(pin.title)"))
                            }.padding(.vertical, 6).tag(pin.id).contextMenu {
                                Button(L10n.tr("Export Markdown")) { export(pin) }
                                Button(L10n.tr("Delete"), role: .destructive) { deleting = pin }
                            }
                        }.scrollContentBackground(.hidden)
                        Text(L10n.tr("Select two items, or ⌘-click to compare")).font(.caption).foregroundStyle(.secondary)
                    }.frame(minWidth: 190, idealWidth: 220, maxWidth: 270)
                    HStack(spacing: 12) {
                        let chosen = Array(model.pins.filter { selection.contains($0.id) }.prefix(2))
                        if chosen.isEmpty { Text(L10n.tr("Select a pin to see details")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        if chosen.count == 2 {
                            OutputComparisonView(before: chosen[1].interaction, after: chosen[0].interaction)
                        } else if let pin = chosen.first {
                            InteractionDetail(item: pin.interaction).frame(minWidth: 200)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.leading, 12)
                }
            }
        }.padding(28)
        .alert(L10n.tr("Delete This Pin?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Delete"), role: .destructive) {
                if let deleting { model.perform { try model.store.delete(Pin.self, id: deleting.id); try model.reload() } }; deleting = nil
            }
        }
    }
    private func export(_ pin: Pin) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.tr("Pinned-interaction.md"); panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let item = pin.interaction
        // A fence longer than any content run preserves embedded Markdown fences.
        let longest = (item.command + item.output).split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let text = L10n.tr("# \(model.displayName(for: item).full)\n\nDate: \(L10n.date(item.date))\n\n\(item.shell)\n\n\(fence)sh\n\(item.command)\n\(fence)\n\n\(fence)text\n\(item.output)\n\(fence)\n")
        model.perform { try text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: UUID?
    @State private var search = ""
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PageHeader(title: L10n.tr("History"), detail: L10n.tr("Records executed commands, keeping up to \(model.settings.historyLimit) entries."))
                Button(L10n.tr("Clear History")) { confirmClear = true }.disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: L10n.tr("A Record of Every Step"), detail: L10n.tr("History appears here after you connect and run commands. Disable saving in Settings.")) { EmptyView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField(L10n.tr("Search commands or hosts"), text: $search).textFieldStyle(.roundedBorder)
                HSplitView {
                    List(model.history.filter { search.isEmpty || $0.command.localizedCaseInsensitiveContains(search) || model.displayName(for: $0).full.localizedCaseInsensitiveContains(search) }, selection: $selection) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.command).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                            HostNameLabel(model.displayName(for: item)).font(.caption2).foregroundStyle(.secondary)
                            Text(L10n.date(item.date, abbreviated: true)).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(item.id).contextMenu { Button(L10n.tr("Pin Interaction")) { model.pin(item) } }
                    }.frame(minWidth: 220, idealWidth: 280, maxWidth: 350).scrollContentBackground(.hidden)
                    if let item = model.history.first(where: { $0.id == selection }) {
                        VStack { InteractionDetail(item: item); Button(L10n.tr("Pin This Interaction")) { model.pin(item) } }.padding(.leading, 16)
                    } else { Text(L10n.tr("Select a command to see its full output")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }.padding(28)
            .alert(L10n.tr("Clear All Command History?"), isPresented: $confirmClear) {
                Button(L10n.tr("Cancel"), role: .cancel) {}
                Button(L10n.tr("Clear"), role: .destructive) { model.perform { try model.store.clearHistory(); try model.reload() } }
            } message: { Text(L10n.tr("Pinned interactions will be kept.")) }
    }
}

struct KnownHostsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PageHeader(title: L10n.tr("Known Hosts"), detail: L10n.tr("Fingerprints are saved after confirmation on first connection. Changed fingerprints block connections."))
                Button(L10n.tr("Refresh")) { load() }
            }
            Text(L10n.tr("Hostnames are stored as hashes. If a server key changes legitimately, verify its new fingerprint through a trusted channel before removing the old record with the command below.")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("ssh-keygen -R '[server-address]:port' -f '\(model.paths.knownHosts.path)'")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            ScrollView([.vertical, .horizontal]) {
                Text(content.isEmpty ? L10n.tr("No trusted hosts yet") : content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
        }.padding(28).onAppear { load() }
    }
    private func load() { model.perform { content = try String(contentsOf: model.paths.knownHosts, encoding: .utf8) } }
}

struct PreferencesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var fontSearch = ""
    @State private var backgroundInput = ""
    @State private var newLocation: URL?
    private var terminalBackground: NSColor {
        TerminalAppearance.background(hex: model.settings.terminalBackgroundHex, dark: colorScheme == .dark)
    }
    private func applyBackgroundInput() {
        if let color = TerminalAppearance.color(hex: backgroundInput) {
            model.settings.terminalBackgroundHex = TerminalAppearance.hex(color)
            backgroundInput = TerminalAppearance.hex(color)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: L10n.tr("Settings"), detail: L10n.tr("Make Bozhou work your way.")).padding(.horizontal, 28).padding(.top, 28)
            Form {
                Section(L10n.tr("Language")) {
                    Picker(L10n.tr("App language"), selection: $model.settings.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Text(L10n.tr("English is the default. Language changes take effect after restarting Bozhou."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("Appearance & Terminal")) {
                    Picker(L10n.tr("Appearance"), selection: $model.settings.appearance) {
                        Text(L10n.tr("System")).tag("system"); Text(L10n.tr("Light")).tag("light"); Text(L10n.tr("Dark")).tag("dark")
                    }
                    TextField(L10n.tr("Search system fonts"), text: $fontSearch)
                    Picker(L10n.tr("Terminal font"), selection: $model.settings.fontName) {
                        ForEach(TerminalAppearance.fonts.filter { fontSearch.isEmpty || $0.localizedCaseInsensitiveContains(fontSearch) || $0 == model.settings.fontName }, id: \.self) { Text($0).tag($0) }
                    }
                    HStack { Text(L10n.tr("Terminal font size")); Slider(value: $model.settings.fontSize, in: 10...36, step: 1); Text("\(Int(model.settings.fontSize)) pt").monospacedDigit().frame(width: 45) }
                    ColorPicker(L10n.tr("Terminal background"), selection: Binding(
                        get: { Color(nsColor: terminalBackground) },
                        set: { model.settings.terminalBackgroundHex = TerminalAppearance.hex(NSColor($0)) }
                    ), supportsOpacity: false)
                    HStack {
                        TextField(L10n.tr("Background hex color"), text: $backgroundInput, prompt: Text("#F1F2F4"))
                            .onSubmit { applyBackgroundInput() }
                        Button(L10n.tr("Apply Color")) { applyBackgroundInput() }
                            .disabled(TerminalAppearance.color(hex: backgroundInput) == nil)
                        Button(L10n.tr("Reset to Default")) {
                            model.settings.terminalBackgroundHex = nil
                            backgroundInput = TerminalAppearance.hex(terminalBackground)
                        }
                    }
                    Text(L10n.tr("Colors apply immediately to all terminals. Defaults are light gray or dark gray depending on appearance. Text color adjusts to the background."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.tr("Bozhou Hello · printf 'Hello world' → 0123456789"))
                        .font(Font(TerminalAppearance.font(model.settings))).textSelection(.enabled)
                        .foregroundStyle(Color(nsColor: TerminalAppearance.foreground(on: terminalBackground)))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color(nsColor: terminalBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                Section(L10n.tr("Connections")) {
                    Toggle(L10n.tr("Reconnect automatically after connection loss"), isOn: $model.settings.autoReconnect)
                    Text(L10n.tr("Retries after 5, 10, 30, 60 and 120 seconds, then requires manual reconnection. Stop retries at any time. Reconnecting starts a new remote shell and keeps recorded interactions.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("History & Notifications")) {
                    Toggle(L10n.tr("Save command history and output"), isOn: $model.settings.saveHistory)
                    Text(L10n.tr("Commands and output may contain sensitive data. Turning this off stops saving history; you can still pin interactions in the current session.")).font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.tr("History limit"), selection: $model.settings.historyLimit) {
                        Text(L10n.tr("500 records")).tag(500); Text(L10n.tr("1000 records")).tag(1000); Text(L10n.tr("3000 records")).tag(3000)
                    }
                    Toggle(L10n.tr("Send a system notification when a connection ends"), isOn: $model.settings.notifications)
                }
                Section(L10n.tr("Local Data")) {
                    Text(model.paths.root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button(L10n.tr("Open in Finder")) { NSWorkspace.shared.open(model.paths.root) }
                    Button(L10n.tr("Change Data Location…")) {
                        let panel = NSOpenPanel()
                        panel.title = L10n.tr("Choose an Empty Data Directory"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                        if panel.runModal() == .OK { newLocation = panel.url }
                    }
                    Text(L10n.tr("The database contains host passwords in plain text. Host fingerprints and logs are also stored here. Private keys stay in their original locations.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("About Bozhou")) {
                    HStack(spacing: 16) { BrandMark(size: 46); VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.tr("Bozhou  \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.tr("Development build"))")).font(.headline)
                        Text("SwiftUI · OpenSSH · SwiftTerm · SQLite").font(.caption).foregroundStyle(.secondary)
                    } }
                    Text(L10n.tr("A home for every connection.")).font(.caption).foregroundStyle(.secondary)
                    Link(destination: AppLinks.repository) {
                        Label(AppLinks.repositoryDisplayName, systemImage: "link")
                    }.font(.caption)
                }
            }.formStyle(.grouped)
        }.onChange(of: model.settings) { _, _ in model.saveSettings() }
            .onAppear { backgroundInput = TerminalAppearance.hex(terminalBackground) }
            .onChange(of: model.settings.terminalBackgroundHex) { _, _ in backgroundInput = TerminalAppearance.hex(terminalBackground) }
            .onChange(of: colorScheme) { _, _ in backgroundInput = TerminalAppearance.hex(terminalBackground) }
            .alert(L10n.tr("Migrate Local Data?"), isPresented: Binding(get: { newLocation != nil }, set: { if !$0 { newLocation = nil } })) {
                Button(L10n.tr("Cancel"), role: .cancel) { newLocation = nil }
                Button(L10n.tr("Migrate and Use")) { if let newLocation { model.changeDataLocation(to: newLocation) }; newLocation = nil }
            } message: { Text(L10n.tr("The database, fingerprints and logs will be copied to \(newLocation?.path ?? ""). The app will switch to and remember this location. The original directory will remain. Close all sessions first.")) }
    }
}
