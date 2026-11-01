import SwiftUI
import UniformTypeIdentifiers
import BozhouCore

struct WorkspaceBackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var backup: WorkspaceBackup?
    @State private var confirm = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.tr("Export Backup…")) { exportBackup() }
                Button(L10n.tr("Import Backup…")) { importBackup() }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            Text(L10n.tr("Backups include saved passwords, hosts, key references, snippets, history, pins, settings, fingerprints and logs. They are not encrypted. Private key files are not included."))
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
        .alert(L10n.tr("Restore Local Data?"), isPresented: $confirm) {
            Button(L10n.tr("Cancel"), role: .cancel) { backup = nil }
            Button(L10n.tr("Choose Location and Restore…")) { restoreBackup() }
        } message: {
            if let backup {
                Text(L10n.tr("Backup from \(L10n.date(backup.createdAt)): \(backup.hosts.count) hosts, \(backup.identities.count) keys, \(backup.history.count) history entries, \(backup.pins.count) pins. Restore into a new folder and switch to it. Your current data directory will remain. Close all sessions first."))
            }
        }
    }
    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bozhou-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).bozhoubackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "bozhoubackup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = model.store, paths = model.paths
        busy = true; message = ""
        Task {
            do {
                try await Task.detached(priority: .utility) { try WorkspaceBackup.capture(store: store, paths: paths).write(to: url) }.value
                message = L10n.tr("Backup exported: \(url.path)")
            } catch { model.report(error) }
            busy = false
        }
    }
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bozhoubackup") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; message = ""
        Task {
            do {
                backup = try await Task.detached(priority: .utility) { try WorkspaceBackup.read(from: url) }.value
                confirm = true
            } catch { model.report(error) }
            busy = false
        }
    }
    private func restoreBackup() {
        guard let snapshot = backup else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose a Parent Folder for Restored Data")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { backup = nil; return }
        let destination = parent.appendingPathComponent("Bozhou-restored-" + UUID().uuidString)
        busy = true
        Task {
            do {
                try model.checkWorkspaceSwitch()
                let paths = try await Task.detached(priority: .utility) { try snapshot.restore(to: destination) }.value
                try model.useRestoredWorkspace(paths)
                message = L10n.tr("Backup restored. Previous data directory retained. Restart Bozhou to apply language changes.")
            } catch { model.report(error) }
            busy = false; backup = nil
        }
    }
}
