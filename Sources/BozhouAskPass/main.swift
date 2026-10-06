import AppKit
import BozhouCore

// A separate short-lived UI process communicates only through stdout with OpenSSH.
L10n.configure(AppLanguage(rawValue: ProcessInfo.processInfo.environment["BOZHOU_LANGUAGE"] ?? "") ?? .english)
L10n.configureSystemUI()
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let hint = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? ""
let confirm = hint == "confirm" || prompt.contains("yes/no")
let cache = confirm ? nil : try? PasswordCache(environment: ProcessInfo.processInfo.environment, prompt: prompt)
if let saved = cache?.takeSavedPassword() { print(saved); exit(0) }
// Automated regression can prove that no UI prompt was needed.
if ProcessInfo.processInfo.environment["BOZHOU_ASKPASS_NONINTERACTIVE"] == "1" { exit(1) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let alert = NSAlert()
alert.messageText = confirm ? L10n.tr("Verify Server Identity") : L10n.tr("SSH Authentication")
alert.informativeText = confirm
    ? L10n.tr("Check the server fingerprint below. Continue only after verifying its identity.\n\n\(prompt)")
    : cache.map { L10n.tr("Enter the password for \($0.host.displayName.full). It will be saved for this host for future connections.\n\n\(prompt)") }
        ?? L10n.tr("Enter the private key passphrase or verification response. This input will not be saved.\n\n\(prompt)")
alert.alertStyle = confirm ? .warning : .informational
alert.addButton(withTitle: confirm ? L10n.tr("Trust and Connect") : L10n.tr("Continue"))
alert.addButton(withTitle: L10n.tr("Cancel"))
let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
if !confirm { alert.accessoryView = field; alert.window.initialFirstResponder = field }
app.activate(ignoringOtherApps: true)
if alert.runModal() == .alertFirstButtonReturn {
    if let cache {
        do {
            try cache.save(field.stringValue)
            DistributedNotificationCenter.default().postNotificationName(.init("BozhouCredentialsChanged"), object: nil)
        }
        catch {
            let failure = NSAlert(); failure.messageText = L10n.tr("Could Not Save Password")
            failure.informativeText = error.localizedDescription; failure.runModal(); exit(1)
        }
    }
    print(confirm ? "yes" : field.stringValue)
    exit(0)
}
exit(1)
