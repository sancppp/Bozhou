import Foundation
import CryptoKit

/// Trust identity for one hop of the configuration which actually failed.
public struct SSHHostKeyEndpoint: Sendable, Equatable {
    public let hostID: UUID
    public let name: String
    public let address: String
    public let port: Int
    public let identifier: String
    public init(host: Host, alias: String?) {
        hostID = host.id; name = host.displayName.full; address = host.address; port = host.port
        identifier = alias ?? (host.port == 22 ? host.address.lowercased() : "[\(host.address.lowercased())]:\(host.port)")
    }
}

/// A changed key is never trusted automatically. This snapshot permits an explicit,
/// narrowly scoped reset, followed by OpenSSH's normal new-key confirmation.
public struct SSHHostKeyFailure: LocalizedError, Sendable {
    public let endpoint: SSHHostKeyEndpoint
    public let fingerprint: String
    private let knownHosts: URL
    private let snapshot: Data
    public var errorDescription: String? { L10n.tr("Server identity changed: \(endpoint.name)") }

    public static func detect(output: String, launch: SSHLaunch) -> Self? {
        guard output.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"),
              output.contains("Host key verification failed"),
              let knownHosts = launch.knownHostsURL else { return nil }
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let identifiers = lines.compactMap { line -> String? in
            let prefix = "Host key for ", suffix = " has changed and you have requested strict checking."
            guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
            return String(line.dropFirst(prefix.count).dropLast(suffix.count)).lowercased()
        }
        // Require a unique hop belonging to this launch. Never use a path or a line
        // number supplied in SSH output to choose which local trust data to change.
        let endpoints = launch.hostKeyEndpoints.filter { identifiers.contains($0.identifier.lowercased()) }
        guard endpoints.count == 1,
              let fingerprint = lines.first(where: {
                  $0.range(of: #"^SHA256:[A-Za-z0-9+/]{43}\.?$"#, options: .regularExpression) != nil
              }),
              let data = try? Data(contentsOf: knownHosts), data.count <= 8 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8),
              remove(identifier: endpoints[0].identifier, from: text) != text else { return nil }
        return Self(endpoint: endpoints[0], fingerprint: fingerprint.hasSuffix(".") ? String(fingerprint.dropLast()) : fingerprint,
                    knownHosts: knownHosts, snapshot: data)
    }

    public func resetTrust() throws {
        // A dialog can stay open while another connection learns a key. Refuse stale
        // snapshots rather than overwriting that connection's trust records.
        guard try Data(contentsOf: knownHosts) == snapshot, let text = String(data: snapshot, encoding: .utf8) else {
            throw BozhouError.invalid(L10n.tr("Saved host keys changed. Reconnect and review the current warning again."))
        }
        let updated = Self.remove(identifier: endpoint.identifier, from: text)
        guard updated != text else { throw BozhouError.invalid(L10n.tr("The old server key is no longer saved. Reconnect to verify its current identity.")) }
        try Data(updated.utf8).write(to: knownHosts, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
    }

    private static func matches(_ token: String, identifier: String) -> Bool {
        if token.hasPrefix("|1|") {
            let parts = token.components(separatedBy: "|")
            guard parts.count == 4, let salt = Data(base64Encoded: parts[2]),
                  let expected = Data(base64Encoded: parts[3]), expected.count == 20 else { return false }
            let actual = HMAC<Insecure.SHA1>.authenticationCode(for: Data(identifier.lowercased().utf8),
                                                              using: SymmetricKey(data: salt))
            return Data(actual) == expected
        }
        return token.lowercased() == identifier.lowercased()
    }

    private static func remove(identifier: String, from text: String) -> String {
        text.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Preserve comments, CA/revocation records and unknown record formats.
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@"),
                  let fieldEnd = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return line }
            let names = String(trimmed[..<fieldEnd]).components(separatedBy: ",")
            let remaining = names.filter { !matches($0, identifier: identifier) }
            guard remaining.count != names.count else { return line }
            if remaining.isEmpty { return nil }
            return remaining.joined(separator: ",") + trimmed[fieldEnd...]
        }.joined(separator: "\n")
    }
}
