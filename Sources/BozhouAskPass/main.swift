import AppKit
import BozhouCore

// A separate short-lived UI process communicates only through stdout with OpenSSH.
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
alert.messageText = confirm ? "确认服务器身份" : "SSH 身份验证"
alert.informativeText = confirm
    ? "请核对以下服务器指纹。仅在确认身份后继续。\n\n\(prompt)"
    : cache.map { "输入 \($0.host.displayName.full) 的密码，将保存到该主机供下次连接使用。\n\n\(prompt)" }
        ?? "请输入私钥口令或验证答案。本次输入不会保存。\n\n\(prompt)"
alert.alertStyle = confirm ? .warning : .informational
alert.addButton(withTitle: confirm ? "信任并连接" : "继续")
alert.addButton(withTitle: "取消")
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
            let failure = NSAlert(); failure.messageText = "密码保存失败"
            failure.informativeText = error.localizedDescription; failure.runModal(); exit(1)
        }
    }
    print(confirm ? "yes" : field.stringValue)
    exit(0)
}
exit(1)
