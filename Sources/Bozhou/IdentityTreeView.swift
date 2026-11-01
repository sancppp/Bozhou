import SwiftUI
import BozhouCore

struct IdentityTreeRow: Identifiable {
    let path: String
    let key: Identity?
    let depth: Int
    var id: String { key.map { $0.id.uuidString } ?? "folder:" + path }
}

struct IdentityTreeView: View {
    @EnvironmentObject var model: AppModel
    let search: String
    let onPublicKey: (Identity) -> Void
    let onEdit: (Identity) -> Void
    let onDelete: (Identity) -> Void
    let onNewFolder: (String) -> Void
    let onRenameFolder: (String) -> Void
    private var expanded: Set<String> {
        search.isEmpty ? model.settings.expandedIdentityGroups : Set(model.identityGroups)
    }
    private var rows: [IdentityTreeRow] {
        let keys = model.identities.filter { key in
            HostTree.contains(key.group, in: model.selectedIdentityGroup) &&
                [key.name, key.group, key.privateKeyPath, key.fingerprint].contains { TextSearch.contains($0, query: search) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let groups = model.identityGroups
        let expanded = expanded
        var result: [IdentityTreeRow] = []
        func visit(_ parent: String, depth: Int) {
            for path in groups where HostTree.parent(path) == parent {
                guard search.isEmpty || TextSearch.contains(path, query: search) ||
                        keys.contains(where: { HostTree.contains($0.group, in: path) }) ||
                        groups.contains(where: { HostTree.contains($0, in: path) && TextSearch.contains($0, query: search) }) else { continue }
                result.append(IdentityTreeRow(path: path, key: nil, depth: depth))
                if expanded.contains(path) { visit(path, depth: depth + 1) }
            }
            for key in keys where key.group == parent {
                result.append(IdentityTreeRow(path: parent, key: key, depth: depth))
            }
        }
        visit(model.selectedIdentityGroup, depth: 0)
        return result
    }
    var body: some View {
        List(rows) { row in
            Group {
                if let key = row.key { keyRow(key) }
                else { folderRow(row.path) }
            }.padding(.leading, CGFloat(row.depth) * 18)
        }.scrollContentBackground(.hidden)
            .overlay {
                if rows.isEmpty {
                    Text(search.isEmpty ? L10n.tr("This folder is empty. Import a key or add a folder.") : L10n.tr("No matches"))
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
    }
    private func folderRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Button {
                guard search.isEmpty else { return }
                model.setIdentityGroupExpanded(path, expanded: !expanded.contains(path))
            } label: {
                Image(systemName: expanded.contains(path) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 16)
            }.buttonStyle(.plain).accessibilityLabel(path)
            Button { model.selectedIdentityGroup = path } label: {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(sea)
                    HighlightedText((path as NSString).lastPathComponent, query: search).font(.headline)
                    Spacer()
                    Text("\(model.identities.filter { HostTree.contains($0.group, in: path) }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.vertical, 5)
            .contextMenu {
                Button(L10n.tr("Open Folder")) { model.selectedIdentityGroup = path }
                Button(L10n.tr("New Subfolder")) { onNewFolder(path) }
                Button(L10n.tr("Rename / Move")) { onRenameFolder(path) }
                Button(L10n.tr("Delete Empty Folder"), role: .destructive) { model.deleteIdentityFolder(path) }
            }
    }
    private func keyRow(_ key: Identity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(sea).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                HighlightedText(key.name, query: search).font(.headline)
                HighlightedText(key.privateKeyPath.isEmpty ? L10n.tr("Public key only · Authenticate with SSH Agent or the associated local private key") : key.privateKeyPath, query: search)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                if !key.fingerprint.isEmpty {
                    HighlightedText(key.fingerprint, query: search).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).help(key.fingerprint)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("Public Key")) { onPublicKey(key) }
            Button { onEdit(key) } label: { Image(systemName: "pencil") }.help(L10n.tr("Rename / Move"))
            Button { onDelete(key) } label: { Image(systemName: "trash") }.help(L10n.tr("Remove key record"))
        }.padding(.vertical, 8)
            .contextMenu {
                Button(L10n.tr("Rename / Move")) { onEdit(key) }
                Menu(L10n.tr("Move to Folder")) {
                    ForEach([""] + model.identityGroups, id: \.self) { group in
                        Button(group.isEmpty ? L10n.tr("All Keys") : group) {
                            var copy = key; copy.group = group
                            model.perform { try model.saveIdentity(copy) }
                        }
                    }
                }
                Button(L10n.tr("Public Key")) { onPublicKey(key) }
                Button(L10n.tr("Remove"), role: .destructive) { onDelete(key) }
            }
    }
}

struct IdentityEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var key: Identity
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("Rename / Move")).font(.title2)
            TextField(L10n.tr("Name"), text: $key.name)
            HStack {
                TextField(L10n.tr("Folder path"), text: $key.group)
                Menu(L10n.tr("Move to Folder")) {
                    ForEach([""] + model.identityGroups, id: \.self) { path in
                        Button(path.isEmpty ? L10n.tr("All Keys") : path) { key.group = path }
                    }
                }.fixedSize()
            }
            Text(L10n.tr("Use / to create nested folders. Leave empty for All Keys.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("Save")) {
                    model.perform { try model.saveIdentity(key); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(key.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 500)
    }
}
