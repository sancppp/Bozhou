import AppKit
import SwiftUI
import BozhouCore

/// Runs inside an isolated signed app. The real updater controls its termination;
/// the production helper replaces it with a signed executable that records launch.
@main
struct NativeUpdateInstallProbe: App {
    @NSApplicationDelegateAdaptor(UpdateProbeDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var updater: AppUpdater
    init() {
        let instance = try! AppModel()
        if ProcessInfo.processInfo.environment["BOZHOU_UPDATE_PROBE_LANGUAGE"] == "zh-Hans" {
            instance.settings.language = .simplifiedChinese
            L10n.configure(.simplifiedChinese)
        }
        _model = StateObject(wrappedValue: instance)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOZHOU_UPDATE_PROBE_ROOT"]!)
        _updater = StateObject(wrappedValue: AppUpdater(fetch: { url, destination, limit, progress in
            let name: String
            switch url.lastPathComponent {
            case "latest": name = "release.json"
            case "SHA256SUMS": name = "SHA256SUMS"
            case "Bozhou-1.3.1-macOS-arm64.zip": name = "Bozhou-1.3.1-macOS-arm64.zip"
            default: throw BozhouError.invalid("Unexpected fixture request")
            }
            let file = root.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= limit else {
                throw BozhouError.invalid("Fixture exceeds the download limit")
            }
            try FileManager.default.copyItem(at: file, to: destination)
            progress(1)
            return 200
        }))
    }
    var body: some Scene {
        Window("Bozhou Update Installation Probe", id: "update-probe") {
            Text("Isolated update installation test").padding(30)
                .background(UpdatePresentation(updater: updater))
                .environmentObject(model)
                .onAppear {
                    delegate.updater = updater
                    delegate.model = model
                    Task { @MainActor in
                        do { try await run() }
                        catch { print("FAIL \(error)"); exit(1) }
                    }
                }
        }.defaultSize(width: 640, height: 400)
    }
    @MainActor private func run() async throws {
        setbuf(stdout, nil)
        let mode = ProcessInfo.processInfo.environment["BOZHOU_UPDATE_PROBE_MODE"]!
        try await wait("main window") { NSApp.windows.contains { $0.title == "Bozhou Update Installation Probe" } }
        let window = NSApp.windows.first { $0.title == "Bozhou Update Installation Probe" }!
        window.orderFront(nil)
        updater.check()
        try await wait("release and update sheet") { !updater.busy && updater.release != nil && !window.sheets.isEmpty }
        updater.download()
        try await wait("verified download") { !updater.busy && updater.ready != nil }
        print("PASS \(mode): real update sheet and verified signed fixture")
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOZHOU_UPDATE_PROBE_ROOT"]!)
        let marker = root.appendingPathComponent("candidate-launched")
        let ready = updater.ready!
        if mode == "cancel" {
            updater.install(model: model)
            updater.cancel()
            try await wait("cancelled preparation") { !updater.busy }
            precondition(!updater.installing && updater.ready == ready && !FileManager.default.fileExists(atPath: marker.path))
            precondition(!window.sheets.isEmpty && delegate.quitRequests == 0)
            let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            precondition(remaining.allSatisfy { !$0.lastPathComponent.hasPrefix(".bozhou-update-") })
            print("PASS cancelled preparation retains download and never quits or starts replacement")
            updater.applicationWillTerminate()
            exit(0)
        }
        if mode == "blocked" {
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            let blocker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: false)
            owner.orderFront(nil)
            owner.beginSheet(blocker, completionHandler: { _ in })
            updater.install(model: model)
            try await wait("dialog-blocked installation timeout", seconds: 15) { !updater.busy }
            precondition(updater.ready == ready && !updater.installing && delegate.quitRequests == 0)
            precondition(updater.status.contains(L10n.tr("Close any open dialogs and try installing the update again.")))
            precondition(!FileManager.default.fileExists(atPath: marker.path))
            owner.endSheet(blocker)
            try await Task.sleep(for: .milliseconds(100))
            precondition(delegate.quitRequests == 0)
            print("PASS an unrelated modal sheet times out without quitting or replacing; verified download retained")
            updater.applicationWillTerminate()
            exit(0)
        }
        // Invoke the same callback as installation confirmation while the real
        // SwiftUI update sheet is attached; its onDismiss must release the handoff.
        updater.install(model: model)
        updater.install(model: model)
        if mode == "reject" {
            try await wait("refused termination error") { !updater.busy && updater.presented && delegate.quitRequests == 1 }
            precondition(!updater.installing && updater.ready == ready)
            precondition(updater.status.contains(L10n.tr("Bozhou did not quit. Try installing the update again.")) &&
                         !FileManager.default.fileExists(atPath: marker.path))
            try await wait("helper staging cleanup") {
                (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .allSatisfy { !$0.lastPathComponent.hasPrefix(".bozhou-update-") }) == true
            }
            print("PASS refused termination reports failure, stops handoff and retains verified download")
            // Retry through the same real sheet. This quit succeeds and completes replacement.
            try await wait("retry sheet") { !window.sheets.isEmpty }
            updater.install(model: model)
        }
        try await wait("application termination", seconds: 15) { false }
    }
    @MainActor private func wait(_ label: String, seconds: Double = 10, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { throw BozhouError.invalid("Timed out: \(label); \(updater.status)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
final class UpdateProbeDelegate: NSObject, NSApplicationDelegate {
    weak var updater: AppUpdater?
    weak var model: AppModel?
    var quitRequests = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitRequests += 1
        precondition(sender.modalWindow == nil && sender.windows.allSatisfy { $0.sheets.isEmpty })
        precondition(updater?.busy == true && updater?.installing == true && updater?.ready != nil)
        print("PASS termination request \(quitRequests): no modal sheets; installation remains busy")
        if ProcessInfo.processInfo.environment["BOZHOU_UPDATE_PROBE_MODE"] == "reject", quitRequests == 1 {
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        updater?.applicationWillTerminate()
        model?.closeAll()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOZHOU_UPDATE_PROBE_ROOT"]!)
        try! "quitRequests=\(quitRequests),sheets=0".write(to: root.appendingPathComponent("parent-terminated"), atomically: true, encoding: .utf8)
    }
}
