import Foundation
import Darwin

/// Each SSH process carries its own host ID, including nested ProxyCommands.
/// No credentials are placed in SSH arguments, environment variables or logs.
public struct PasswordCache {
    private let store: Store
    public let host: Host
    private let marker: URL

    public init?(environment: [String: String], prompt: String) throws {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only password prompts may reuse or persist a password, never key passphrases or OTPs.
        guard normalized == "password:" || normalized.hasSuffix("'s password:") ||
                normalized.hasSuffix(" password:"),
              !normalized.contains("passphrase"), !normalized.contains("one-time"),
              !normalized.contains("verification"), !normalized.contains("new password"),
              let id = environment["BOZHOU_AUTH_HOST"].flatMap(UUID.init(uuidString:)),
              let database = environment["BOZHOU_AUTH_DATABASE"],
              let directory = environment["BOZHOU_AUTH_SESSION"],
              FileManager.default.fileExists(atPath: database) else { return nil }
        let store = try Store(url: URL(fileURLWithPath: database))
        guard let host = try store.list(Host.self).first(where: { $0.id == id }),
              host.authentication == .password || host.authentication == .agent else { return nil }
        self.store = store; self.host = host
        marker = URL(fileURLWithPath: directory).appendingPathComponent("password-attempt-\(id.uuidString)")
    }

    /// Consume at most once per host per connection; rejected passwords fall back to the UI.
    public func takeSavedPassword() -> String? {
        guard !host.password.isEmpty else { return nil }
        let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { return nil }
        close(fd)
        return host.password
    }

    public func save(_ value: String) throws {
        let fd = open(marker.path, O_CREAT | O_WRONLY, 0o600)
        if fd >= 0 { close(fd) }
        try store.savePassword(value, hostID: host.id)
    }
}
