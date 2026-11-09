import AppKit
import SwiftUI
import BozhouCore

@MainActor
final class AppUpdater: ObservableObject {
    typealias Fetch = @Sendable (URL, URL, Int64, @escaping @Sendable (Double) -> Void) async throws -> Int
    @Published var presented = false
    @Published private(set) var release: ReleaseUpdate?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var ready: URL?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var installing = false
    private struct Installation {
        let directory: URL
        let version: String
        let language: String
    }
    private var pendingInstallation: Installation?
    private var dismissalObserver: NSObjectProtocol?
    private var dismissalTimeout: Task<Void, Never>?
    private let fetch: Fetch
    private var task: Task<Void, Never>?
    private var checkedOnLaunch = false
    private var downloadDirectory: URL?
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    init(fetch: @escaping Fetch = { url, file, limit, progress in
        try await UpdateDownload(limit: limit, progress: progress).fetch(url, to: file)
    }) { self.fetch = fetch }
    deinit {
        dismissalTimeout?.cancel()
        if let dismissalObserver { NotificationCenter.default.removeObserver(dismissalObserver) }
    }

    func checkOnLaunch() {
        guard !checkedOnLaunch else { return }
        checkedOnLaunch = true
        check(manual: false)
    }
    func check(manual: Bool = true) {
        if manual && !installing { presented = true }
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
                let code = try await fetch(ReleaseUpdate.endpoint, file, 2 * 1024 * 1024, { _ in })
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
    func cancel() {
        task?.cancel()
        if let pending = pendingInstallation {
            pendingInstallation = nil; stopWaitingForDismissal()
            try? FileManager.default.removeItem(at: pending.directory)
            busy = false; installing = false; status = L10n.tr("Update cancelled")
            presented = true
        }
    }
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
                let checksumStatus = try await fetch(release.checksums, sums, 1024 * 1024, { _ in })
                guard checksumStatus == 200 else { throw serverError(checksumStatus) }
                let checksum = try ReleaseUpdate.checksum(String(contentsOf: sums, encoding: .utf8), filename: release.filename)
                let downloadStatus = try await fetch(release.archive, zip, release.size, { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                })
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
        busy = true; installing = true; status = L10n.tr("Preparing installation…")
        let language = model.settings.language.rawValue
        task = Task {
            defer { task = nil }
            var staging: URL?
            do {
                let worker = Task.detached(priority: .utility) { () throws -> URL in
                    let fm = FileManager.default
                    try Task.checkCancellation()
                    try UpdateArchive.verifyApp(target)
                    let directory = target.deletingLastPathComponent().appendingPathComponent(".bozhou-update-" + UUID().uuidString)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    do {
                        let app = directory.appendingPathComponent("泊舟.app")
                        try Task.checkCancellation()
                        try fm.copyItem(at: ready, to: app)
                        try UpdateArchive.verifyApp(app, version: release.version.description)
                        let helper = directory.appendingPathComponent("BozhouUpdater")
                        try fm.copyItem(at: target.appendingPathComponent("Contents/MacOS/BozhouUpdater"), to: helper)
                        try fm.copyItem(at: target.appendingPathComponent("Contents/Resources/Bozhou_BozhouCore.bundle"),
                                        to: directory.appendingPathComponent("Bozhou_BozhouCore.bundle"))
                        try Task.checkCancellation()
                        return directory
                    } catch { try? fm.removeItem(at: directory); throw error }
                }
                let folder = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                    onCancel: { worker.cancel() })
                staging = folder
                try Task.checkCancellation()
                pendingInstallation = Installation(directory: folder, version: release.version.description, language: language)
                status = L10n.tr("Closing the update window…")
                // SwiftUI's onDismiss may precede AppKit's sheet teardown. Observe the
                // native completion before requesting dismissal, then recheck the windows.
                dismissalObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                                           object: nil, queue: .main) { [weak self, weak model] _ in
                    DispatchQueue.main.async {
                        guard let self, let model else { return }
                        self.presentationDidDismiss(model: model)
                    }
                }
                dismissalTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, let pending = pendingInstallation else { return }
                    pendingInstallation = nil; stopWaitingForDismissal()
                    try? FileManager.default.removeItem(at: pending.directory)
                    busy = false; installing = false
                    status = L10n.tr("Could not install the update: \(L10n.tr("Close any open dialogs and try installing the update again."))")
                    presented = true
                }
                if presented { presented = false }
                else { presentationDidDismiss(model: model) }
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                busy = false; installing = false
                status = Task.isCancelled ? L10n.tr("Update cancelled") : L10n.tr("Could not install the update: \(error.localizedDescription)")
            }
        }
    }
    func presentationDidDismiss(model: AppModel) {
        guard !presented, let installation = pendingInstallation,
              NSApp.modalWindow == nil, NSApp.windows.allSatisfy({ $0.sheets.isEmpty }) else { return }
        pendingInstallation = nil
        stopWaitingForDismissal()
        let helper = Process()
        do {
            let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            helper.executableURL = installation.directory.appendingPathComponent("BozhouUpdater")
            helper.arguments = [String(ProcessInfo.processInfo.processIdentifier), target.path, installation.version, installation.language]
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run()
            status = L10n.tr("Restarting to install the update…")
            model.closeAll()
            NSApp.terminate(nil)
            // Successful termination exits this process. A refused quit must not leave
            // a helper waiting to replace the app during a later, unrelated shutdown.
            throw BozhouError.invalid(L10n.tr("Bozhou did not quit. Try installing the update again."))
        } catch {
            if helper.isRunning { helper.terminate() }
            try? FileManager.default.removeItem(at: installation.directory)
            busy = false; installing = false
            status = L10n.tr("Could not install the update: \(error.localizedDescription)")
            presented = true
        }
    }
    private func stopWaitingForDismissal() {
        dismissalTimeout?.cancel(); dismissalTimeout = nil
        if let dismissalObserver { NotificationCenter.default.removeObserver(dismissalObserver) }
        dismissalObserver = nil
    }
    func applicationWillTerminate() { discardDownload() }
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
        Color.clear.frame(width: 0, height: 0).sheet(isPresented: $updater.presented, onDismiss: {
            updater.presentationDidDismiss(model: model)
        }) {
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
                        .disabled(updater.installing)
                    Spacer()
                    if updater.busy { Button(L10n.tr("Cancel")) { updater.cancel() } }
                    else if updater.ready != nil {
                        Button(L10n.tr("Install and Restart")) { confirm = true }.buttonStyle(.borderedProminent)
                    } else if updater.release != nil {
                        Button(L10n.tr("Download Update")) { updater.download() }.buttonStyle(.borderedProminent)
                    } else { Button(L10n.tr("Check Again")) { updater.check() } }
                }
            }.padding(26).frame(width: 540)
                .interactiveDismissDisabled(updater.installing)
                .alert(L10n.tr("Install Update and Restart?"), isPresented: $confirm) {
                    Button(L10n.tr("Cancel"), role: .cancel) {}
                    Button(L10n.tr("Install and Restart")) { updater.install(model: model) }
                } message: { Text(L10n.tr("Terminal and SFTP connections will close. Your local data and the previous app will be kept.")) }
        }
    }
}
