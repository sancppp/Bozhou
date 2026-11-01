import AppKit
import BozhouCore

// This helper is copied outside the running bundle before launch.
let arguments = CommandLine.arguments
guard arguments.count == 5, let pid = Int32(arguments[1]), pid > 1,
      ReleaseVersion(arguments[3]) != nil else { exit(2) }
L10n.configure(AppLanguage(rawValue: arguments[4]) ?? .english)
let directory = URL(fileURLWithPath: arguments[0]).standardizedFileURL.deletingLastPathComponent()
let target = URL(fileURLWithPath: arguments[2]).standardizedFileURL
let candidate = directory.appendingPathComponent("泊舟.app")
do {
    guard directory.lastPathComponent.hasPrefix(".bozhou-update-"),
          directory.deletingLastPathComponent() == target.deletingLastPathComponent(),
          target.pathExtension == "app" else { throw BozhouError.invalid(L10n.tr("Update verification or installation failed")) }
    // Give the main app time to finish shutdown; never replace a still-running process.
    let deadline = Date().addingTimeInterval(120)
    while kill(pid, 0) == 0 || errno == EPERM {
        guard Date() < deadline else { throw BozhouError.invalid(L10n.tr("Bozhou did not quit. Try installing the update again.")) }
        usleep(200_000)
    }
    try UpdateArchive.verifyApp(target)
    try AppReplacement.commit(staged: candidate, target: target,
                              validate: { try UpdateArchive.verifyApp($0, version: arguments[3]) },
                              launch: { try UpdateArchive.run("/usr/bin/open", ["-n", $0.path]) })
    try? FileManager.default.removeItem(at: directory)
} catch {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = L10n.tr("Update Could Not Be Installed")
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: L10n.tr("OK"))
    app.activate(ignoringOtherApps: true)
    alert.runModal()
    if (try? UpdateArchive.verifyApp(target)) != nil { NSWorkspace.shared.open(target) }
    exit(1)
}
