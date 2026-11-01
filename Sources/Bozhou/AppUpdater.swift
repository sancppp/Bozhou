import AppKit
import SwiftUI
import BozhouCore

@MainActor
final class AppUpdater: ObservableObject {
    @Published var presented = false
    @Published private(set) var release: ReleaseUpdate?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var ready: URL?
    @Published private(set) var checkedAt: Date?
    private var task: Task<Void, Never>?
    private var checkedOnLaunch = false
    private var downloadDirectory: URL?
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    func checkOnLaunch() {
        guard !checkedOnLaunch else { return }
        checkedOnLaunch = true
        check(manual: false)
    }
    func check(manual: Bool = true) {
        if manual { presented = true }
        guard !busy else { return }
        discardDownload()
        ready = nil; release = nil
        busy = true; progress = 0; status = L10n.tr("Checking GitHub for updates…")
        task = Task {
            defer { busy = false; task = nil }
            var temporary: URL?
            do {
                let directory = try makeDownloadDirectory(); temporary = directory
                let file = directory.appendingPathComponent("release.json")
                let code = try await UpdateDownload(limit: 2 * 1024 * 1024).fetch(ReleaseUpdate.endpoint, to: file)
                guard code == 200 || code == 404 else { throw serverError(code) }
                let found = code == 404 ? nil : try ReleaseUpdate.parse(Data(contentsOf: file), current: ReleaseVersion(currentVersion) ?? ReleaseVersion("0.0.0")!)
                try Task.checkCancellation()
                release = found; checkedAt = Date()
                if let found {
                    status = L10n.tr("Bozhou \(found.version.description) is available")
                    if !manual { presented = true }
                } else { status = L10n.tr("Bozhou is up to date") }
            } catch is CancellationError { status = L10n.tr("Update cancelled") }
            catch { status = Task.isCancelled ? L10n.tr("Update cancelled") : error.localizedDescription }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
    }
    func cancel() { task?.cancel() }
    func download() {
        guard !busy, let release else { return }
        busy = true; progress = 0; status = L10n.tr("Downloading update…")
        task = Task {
            var directory: URL?
            defer { busy = false; task = nil }
            do {
                discardDownload()
                ready = nil
                let folder = try makeDownloadDirectory(); directory = folder; downloadDirectory = folder
                let zip = folder.appendingPathComponent(release.filename), sums = folder.appendingPathComponent("SHA256SUMS")
                let checksumStatus = try await UpdateDownload(limit: 1024 * 1024).fetch(release.checksums, to: sums)
                guard checksumStatus == 200 else { throw serverError(checksumStatus) }
                let checksum = try ReleaseUpdate.checksum(String(contentsOf: sums, encoding: .utf8), filename: release.filename)
                let downloadStatus = try await UpdateDownload(limit: release.size, progress: { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }).fetch(release.archive, to: zip)
                guard downloadStatus == 200 else { throw serverError(downloadStatus) }
                status = L10n.tr("Verifying update…")
                let worker = Task.detached(priority: .utility) {
                    try ReleaseUpdate.verify(file: zip, sha256: checksum)
                    try Task.checkCancellation()
                    let app = try UpdateArchive.extract(zip, into: folder.appendingPathComponent("extracted"))
                    try Task.checkCancellation()
                    try UpdateArchive.verifyApp(app, version: release.version.description)
                    return app
                }
                let app = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                ready = app; progress = 1; status = L10n.tr("Update verified. Ready to install.")
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                downloadDirectory = nil; ready = nil
                status = Task.isCancelled ? L10n.tr("Update cancelled") : error.localizedDescription
            }
        }
    }
    func install(model: AppModel) {
        guard !busy, let ready, let release else { return }
        let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard target.pathExtension == "app", !target.path.hasPrefix("/Volumes/") else {
            status = L10n.tr("Move Bozhou to a writable Applications folder before updating"); return
        }
        busy = true; status = L10n.tr("Preparing installation…")
        let language = model.settings.language.rawValue
        task = Task {
            defer { busy = false; task = nil }
            var staging: URL?
            do {
                let worker = Task.detached(priority: .utility) { () throws -> URL in
                    let fm = FileManager.default
                    try UpdateArchive.verifyApp(target)
                    let directory = target.deletingLastPathComponent().appendingPathComponent(".bozhou-update-" + UUID().uuidString)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    do {
                        let app = directory.appendingPathComponent("泊舟.app")
                        try fm.copyItem(at: ready, to: app)
                        try UpdateArchive.verifyApp(app, version: release.version.description)
                        let helper = directory.appendingPathComponent("BozhouUpdater")
                        try fm.copyItem(at: target.appendingPathComponent("Contents/MacOS/BozhouUpdater"), to: helper)
                        try fm.copyItem(at: target.appendingPathComponent("Contents/Resources/Bozhou_BozhouCore.bundle"),
                                        to: directory.appendingPathComponent("Bozhou_BozhouCore.bundle"))
                        return directory
                    } catch { try? fm.removeItem(at: directory); throw error }
                }
                let folder = try await worker.value; staging = folder
                try Task.checkCancellation()
                let helper = Process()
                helper.executableURL = folder.appendingPathComponent("BozhouUpdater")
                helper.arguments = [String(ProcessInfo.processInfo.processIdentifier), target.path, release.version.description, language]
                helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
                try helper.run()
                discardDownload()
                model.closeAll()
                NSApp.terminate(nil)
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                status = Task.isCancelled ? L10n.tr("Update cancelled") : L10n.tr("Could not install the update: \(error.localizedDescription)")
            }
        }
    }
    private func discardDownload() {
        if let directory = downloadDirectory { try? FileManager.default.removeItem(at: directory) }
        downloadDirectory = nil; ready = nil
    }
    private func makeDownloadDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.bozhou.ssh/Updates").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func serverError(_ code: Int) -> BozhouError {
        .invalid(code == 403 || code == 429 ? L10n.tr("GitHub rate limit reached. Try again later.") :
                    L10n.tr("GitHub update request failed (HTTP \(code))"))
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("Bozhou checks for GitHub releases at every launch. Downloads and installation require your confirmation."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.tr("Check for Updates…")) { updater.check() }
            if let checked = updater.checkedAt {
                Text(L10n.tr("Last checked: \(L10n.date(checked))")).font(.caption).foregroundStyle(.secondary)
            }
            if !updater.status.isEmpty { Text(updater.status).font(.caption) }
        }
    }
}

struct UpdatePresentation: View {
    @ObservedObject var updater: AppUpdater
    @EnvironmentObject var model: AppModel
    @State private var confirm = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).sheet(isPresented: $updater.presented) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("Software Update")).font(.title2.weight(.semibold))
                Text(L10n.tr("Installed version: \(updater.currentVersion)")).font(.caption).foregroundStyle(.secondary)
                Text(updater.status).textSelection(.enabled)
                if let release = updater.release {
                    ScrollView { Text(release.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 240)
                    Link(L10n.tr("View Release on GitHub"), destination: release.page)
                }
                if updater.busy { ProgressView(value: updater.progress) }
                HStack {
                    Button(L10n.tr("Close")) { updater.presented = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if updater.busy { Button(L10n.tr("Cancel")) { updater.cancel() } }
                    else if updater.ready != nil {
                        Button(L10n.tr("Install and Restart")) { confirm = true }.buttonStyle(.borderedProminent)
                    } else if updater.release != nil {
                        Button(L10n.tr("Download Update")) { updater.download() }.buttonStyle(.borderedProminent)
                    } else { Button(L10n.tr("Check Again")) { updater.check() } }
                }
            }.padding(26).frame(width: 540)
                .alert(L10n.tr("Install Update and Restart?"), isPresented: $confirm) {
                    Button(L10n.tr("Cancel"), role: .cancel) {}
                    Button(L10n.tr("Install and Restart")) { updater.install(model: model) }
                } message: { Text(L10n.tr("Terminal and SFTP connections will close. Your local data and the previous app will be kept.")) }
        }
    }
}
