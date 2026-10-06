import SwiftUI
import BozhouCore

struct HostEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var environment = ""
    @State private var validation: String?
    @State private var proxyEnabled = false
    @State private var proxy = ProxyConfiguration()
    @State private var jumpSelection: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(sea)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hosts.contains { $0.id == host.id } ? L10n.tr("Host Details") : L10n.tr("New Host")).font(.title3.weight(.semibold))
                    Text(L10n.tr("Save connection settings for your next session")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            Form {
                Section(L10n.tr("Basic Information")) {
                    TextField(L10n.tr("Name"), text: $host.name)
                    TextField(L10n.tr("Address"), text: $host.address, prompt: Text("example.com / 192.168.1.10"))
                    TextField(L10n.tr("Port"), value: $host.port, format: .number.grouping(.never))
                    TextField(L10n.tr("Username"), text: $host.username)
                    TextField(L10n.tr("Folder path"), text: $host.group, prompt: Text(L10n.tr("e.g. Production/US East")))
                    if !model.groups.isEmpty {
                        Picker(L10n.tr("Existing folder"), selection: $host.group) {
                            Text(L10n.tr("Root")).tag("")
                            ForEach(Array(Set(model.groups + (host.group.isEmpty ? [] : [host.group]))).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField(L10n.tr("Tags"), text: $host.tags, prompt: Text(L10n.tr("Separate with spaces")))
                    Picker(L10n.tr("Icon color"), selection: $host.color) {
                        Text(L10n.tr("Blue")).tag("blue"); Text(L10n.tr("Mint")).tag("mint"); Text(L10n.tr("Orange")).tag("orange")
                    }
                    Toggle(L10n.tr("Favorite host"), isOn: $host.favorite)
                }
                Section {
                    Picker(L10n.tr("Login method"), selection: $host.authentication) {
                        ForEach(Authentication.allCases) { auth in Text(auth.title).tag(auth) }
                    }
                    if host.authentication == .identity {
                        Picker(L10n.tr("Private Key"), selection: $host.identityID) {
                            Text(L10n.tr("Select")).tag(nil as UUID?)
                            ForEach(model.identities) { key in Text(key.name).tag(Optional(key.id)) }
                        }
                        Text(L10n.tr("The matching private key file is required. Import it in Keys first, or use SSH Agent.")).font(.caption).foregroundStyle(.secondary)
                    } else if host.authentication == .kerberos {
                        Text(L10n.tr("Uses the local Kerberos ticket cache (kinit or enterprise sign-in). Enter the remote username. No password is needed and tickets are not delegated.")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        SecureField(L10n.tr("Password"), text: $host.password, prompt: Text(L10n.tr("Leave empty to enter at first connection")))
                        Text(host.authentication == .password
                             ? L10n.tr("Passwords are stored locally in plain text. The destination and each jump host reuse their own saved username and password.")
                             : L10n.tr("SSH Agent is tried first. This password is reused for password fallback and stored locally in plain text after first entry."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.tr("Authentication")) }
                Section {
                    ForEach(Array(host.jumpHosts.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
                            if let jump = model.hosts.first(where: { $0.id == id }) { HostNameLabel(jump.displayName) }
                            else { Text(L10n.tr("Deleted host")) }
                            Spacer()
                            Button {
                                guard let current = host.jumpHosts.firstIndex(of: id), current > 0 else { return }
                                host.jumpHosts.swapAt(current, current - 1)
                            } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                            Button { host.jumpHosts.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        }
                    }
                    HStack {
                        HostPicker(title: L10n.tr("Add jump host"),
                                   hosts: model.hosts.filter { $0.id != host.id && !host.jumpHosts.contains($0.id) },
                                   selection: $jumpSelection)
                        Button(L10n.tr("Add")) {
                            if let id = jumpSelection { host.jumpHosts.append(id); jumpSelection = nil }
                        }.disabled(jumpSelection == nil)
                    }
                    Text(L10n.tr("Connects in order, expanding any nested jump hosts. Each hop can use a different port and authentication method."))
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text(L10n.tr("Jump Host Chain")) }
                Section(L10n.tr("Terminal Environment")) {
                    TextField(L10n.tr("Default shell"), text: $host.shell, prompt: Text(L10n.tr("Leave empty to use the login shell")))
                    Text(L10n.tr("Environment variables (one NAME=value per line)")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $environment).font(.system(size: 12, design: .monospaced)).frame(height: 75)
                    Text(L10n.tr("Bash and Zsh support automatic interaction recording. Other shells support manual snapshots.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("Network Proxy")) {
                    Toggle(L10n.tr("Enable proxy"), isOn: $proxyEnabled)
                    if proxyEnabled {
                        Picker(L10n.tr("Protocol"), selection: $proxy.kind) {
                            Text("SOCKS5").tag(ProxyKind.socks5); Text("HTTP CONNECT").tag(ProxyKind.http)
                        }
                        TextField(L10n.tr("Proxy address"), text: $proxy.host)
                        TextField(L10n.tr("Proxy port"), value: $proxy.port, format: .number.grouping(.never))
                        Text(L10n.tr("Supports proxies without authentication, on a direct host or the first jump host.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.tr("Local Port Forwarding")) {
                    ForEach(host.forwards) { forward in
                        LocalForwardEditor(forward: $host.forwards.element(forward)) {
                            host.forwards.removeAll { $0.id == forward.id }
                        }
                    }
                    Button(L10n.tr("Add Forward")) { host.forwards.append(LocalForward()) }
                    Text(L10n.tr("Starts with the terminal connection, listens only on local 127.0.0.1, and stops when the session closes. Example: local 58080 → server 127.0.0.1:80.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("Login & System Information")) {
                    LabeledContent(L10n.tr("Hostname")) {
                        Text(host.systemProfile?.hostname ?? L10n.tr("Collected at next login"))
                            .textSelection(.enabled)
                    }
                    LabeledContent(L10n.tr("Date added"), value: L10n.date(host.createdAt))
                    LabeledContent(L10n.tr("Last successful login"), value: host.lastLoginAt.map { L10n.date($0) } ?? L10n.tr("Never logged in"))
                    if let profile = host.systemProfile {
                        LabeledContent(L10n.tr("Collected at"), value: L10n.date(profile.collectedAt))
                        profileField(L10n.tr("Operating system"), profile.operatingSystem)
                        profileField(L10n.tr("Kernel & architecture"), profile.kernel)
                        profileField("CPU", profile.cpu)
                        profileField(L10n.tr("Memory"), profile.memory)
                    }
                    Text(L10n.tr("Each login updates hostname, OS, CPU and memory information using read-only commands.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("Notes")) { TextEditor(text: $host.notes).frame(height: 55) }
            }.formStyle(.grouped)
            if let validation { Label(validation, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).padding(12) }
            Divider()
            HStack {
                Button(L10n.tr("Cancel")) { dismiss() }
                Spacer()
                Button(L10n.tr("Save")) { save(connect: false) }
                Button(L10n.tr("Save and Connect")) { save(connect: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.controlSize(.large).padding(20)
        }.frame(width: 540, height: 740).tint(sea)
            .onAppear {
                environment = host.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                proxyEnabled = host.proxy != nil; proxy = host.proxy ?? ProxyConfiguration()
            }
    }
    private func profileField(_ title: String, _ value: String) -> some View {
        DisclosureGroup(title) {
            Text(value.isEmpty ? L10n.tr("System did not provide this information") : value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func save(connect: Bool) {
        do {
            var values: [String: String] = [:]
            for line in environment.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let equal = line.firstIndex(of: "=") else { throw BozhouError.invalid(L10n.tr("Environment variables must use NAME=value")) }
                let name = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
                guard values[name] == nil else { throw BozhouError.invalid(L10n.tr("Duplicate environment variable: \(name)")) }
                values[name] = String(line[line.index(after: equal)...])
            }
            host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
            host.address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
            host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
            host.environment = values; host.proxy = proxyEnabled ? proxy : nil
            try model.saveHost(host)
            if connect { model.connect(host) }
            dismiss()
        } catch { validation = error.localizedDescription }
    }
}

private struct LocalForwardEditor: View {
    @Binding var forward: LocalForward
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Toggle(L10n.tr("Enable"), isOn: $forward.enabled)
                Spacer()
                Button(L10n.tr("Remove"), action: remove)
            }
            TextField(L10n.tr("Local port"), value: $forward.localPort, format: .number.grouping(.never))
            TextField(L10n.tr("Destination address (as seen by the server)"), text: $forward.remoteHost)
            TextField(L10n.tr("Destination port"), value: $forward.remotePort, format: .number.grouping(.never))
        }
    }
}
