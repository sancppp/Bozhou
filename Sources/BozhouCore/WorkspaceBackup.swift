import Foundation
import CryptoKit

/// Versioned logical backup. Import decodes typed records, never executes an imported database.
public struct WorkspaceBackup: Codable {
    public struct LogFile: Codable {
        public var name: String
        public var data: Data
    }
    public var hosts: [Host]
    public var folders: [HostFolder]
    public var identities: [Identity]
    public var identityFolders: [IdentityFolder]
    public var snippets: [Snippet]
    public var history: [Interaction]
    public var pins: [Pin]
    public var settings: AppSettings
    public var knownHosts: Data
    public var logs: [LogFile]
    public var createdAt: Date

    private struct Envelope: Codable {
        var format: String = "dev.bozhou.backup"
        var version: Int = 1
        var sha256: String
        var payload: Data
    }
    public static let maximumBytes = 512 * 1024 * 1024
    private static var invalid: BozhouError { .storage(L10n.tr("Invalid or unsupported Bozhou backup")) }

    public static func capture(store: Store, paths: AppPaths) throws -> WorkspaceBackup {
        var snapshot: WorkspaceBackup!
        // Serialize all tables together, including committed WAL changes.
        try store.transaction {
            snapshot = try WorkspaceBackup(hosts: store.list(Host.self), folders: store.list(HostFolder.self),
                identities: store.list(Identity.self), identityFolders: store.list(IdentityFolder.self),
                snippets: store.list(Snippet.self), history: store.list(Interaction.self), pins: store.list(Pin.self),
                settings: store.loadSettings(), knownHosts: Data(), logs: [], createdAt: Date())
        }
        var bytes = 0
        func read(_ url: URL) throws -> Data {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalid }
            bytes += values.fileSize ?? maximumBytes
            guard bytes <= maximumBytes else { throw BozhouError.storage(L10n.tr("Backup exceeds the 512 MiB limit")) }
            return try Data(contentsOf: url)
        }
        snapshot.knownHosts = try read(paths.knownHosts)
        for url in try FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil) {
            snapshot.logs.append(LogFile(name: url.lastPathComponent, data: try read(url)))
        }
        return snapshot
    }

    public func write(to url: URL) throws {
        try validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(self)
        let data = try encoder.encode(Envelope(sha256: Self.digest(payload), payload: payload))
        guard data.count <= Self.maximumBytes else { throw BozhouError.storage(L10n.tr("Backup exceeds the 512 MiB limit")) }
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".bozhou-backup-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let file = staging.appendingPathComponent("backup")
        try data.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Atomic replacement publishes only the fully written, owner-only file.
        guard rename(file.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func read(from url: URL) throws -> WorkspaceBackup {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes + 1
        guard size <= maximumBytes else { throw BozhouError.storage(L10n.tr("Backup exceeds the 512 MiB limit")) }
        do {
            let decoder = PropertyListDecoder()
            let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.format == "dev.bozhou.backup", envelope.version == 1,
                  digest(envelope.payload) == envelope.sha256 else { throw invalid }
            let backup = try decoder.decode(Self.self, from: envelope.payload)
            try backup.validate()
            return backup
        } catch { throw invalid }
    }

    public func restore(to destination: URL) throws -> AppPaths {
        try validate()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw BozhouError.storage(L10n.tr("Destination already exists"))
        }
        // The caller switches only after success. Its previous workspace remains untouched.
        do {
            let paths = try AppPaths(root: destination)
            let store = try Store(url: paths.database)
            try store.transaction {
                for row in hosts.reversed() { try store.save(row) }
                for row in folders.reversed() { try store.save(row) }
                for row in identities.reversed() { try store.save(row) }
                for row in identityFolders.reversed() { try store.save(row) }
                for row in snippets.reversed() { try store.save(row) }
                for row in history.reversed() { try store.save(row) }
                for row in pins.reversed() { try store.save(row) }
                try store.saveSettings(settings)
            }
            try knownHosts.write(to: paths.knownHosts, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.knownHosts.path)
            for log in logs {
                let file = paths.logs.appendingPathComponent(log.name)
                try log.data.write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            return paths
        } catch { try? fm.removeItem(at: destination); throw error }
    }

    private func validate() throws {
        func unique<T: Record>(_ rows: [T]) -> Bool { Set(rows.map(\.id)).count == rows.count }
        guard unique(hosts), unique(folders), unique(identities), unique(identityFolders),
              unique(snippets), unique(history), unique(pins),
              Set(logs.map(\.name)).count == logs.count,
              logs.allSatisfy({ !$0.name.isEmpty && $0.name != "." && $0.name != ".." &&
                  !$0.name.contains("/") && !$0.name.contains("\\") && !$0.name.contains("\0") }) else { throw Self.invalid }
        let hostIDs = Set(hosts.map(\.id)), keyIDs = Set(identities.map(\.id))
        guard hosts.allSatisfy({ Set($0.jumpHosts).isSubset(of: hostIDs) && ($0.identityID == nil || keyIDs.contains($0.identityID!)) }) else {
            throw Self.invalid
        }
        for path in folders.map(\.path) + hosts.map(\.group) + identityFolders.map(\.path) + identities.map(\.group) {
            guard (try? HostTree.normalize(path)) == path else { throw Self.invalid }
        }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
