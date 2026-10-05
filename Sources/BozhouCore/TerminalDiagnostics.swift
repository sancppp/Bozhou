import Foundation

/// One bounded, private report per abnormal exit. No environment, SSH config or input stream.
public struct TerminalDiagnostic: Codable {
    public var schemaVersion = 1
    public var date = Date()
    public var sessionID: UUID
    public var connectionID: String
    public var hostID: UUID?
    public var hostName: String
    public var shell: String
    public var reason: String
    public var waitStatus: Int32?
    public var processExitCode: Int?
    public var processSignal: Int?
    public var shellExitCode: Int?
    public var connectedSeconds: Double?
    public var columns: Int
    public var rows: Int
    public var terminalTail: String
    public var sshTail: String
    public var interactions: [Interaction]

    public init(sessionID: UUID, connectionID: String, hostID: UUID?, hostName: String, shell: String,
                reason: String, waitStatus: Int32?, shellExitCode: Int?, connectedSeconds: Double?,
                columns: Int, rows: Int, terminalTail: String, sshTail: String, interactions: [Interaction],
                secrets: [String] = []) {
        self.sessionID = sessionID; self.connectionID = connectionID
        self.hostID = hostID; self.hostName = hostName; self.shell = shell; self.reason = reason
        self.waitStatus = waitStatus; self.shellExitCode = shellExitCode
        processExitCode = Self.exitCode(waitStatus)
        processSignal = waitStatus.flatMap { ($0 & 0x7f) == 0 ? nil : Int($0 & 0x7f) }
        self.connectedSeconds = connectedSeconds; self.columns = columns; self.rows = rows
        func bounded(_ text: String, bytes: Int) -> String {
            var text = text
            for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "[REDACTED]") }
            // Skip a split UTF-8 scalar so replacement characters cannot exceed the cap.
            let tail = text.utf8.suffix(bytes).drop { ($0 & 0xc0) == 0x80 }
            return String(decoding: tail, as: UTF8.self)
        }
        self.connectionID = bounded(connectionID, bytes: 256)
        self.hostName = bounded(hostName, bytes: 1024)
        self.shell = bounded(shell, bytes: 1024)
        self.reason = bounded(reason, bytes: 256)
        self.terminalTail = bounded(terminalTail, bytes: 64 * 1024)
        self.sshTail = bounded(sshTail, bytes: 16 * 1024)
        self.interactions = interactions.prefix(5).map {
            var item = $0
            item.hostName = bounded(item.hostName, bytes: 1024)
            item.hostname = item.hostname.map { bounded($0, bytes: 1024) }
            item.shell = bounded(item.shell, bytes: 1024)
            item.command = bounded(item.command, bytes: 4096)
            item.output = bounded(item.output, bytes: 8192)
            item.truncated = item.truncated || item.output != $0.output || item.command != $0.command
            return item
        }
    }

    public static func exitCode(_ waitStatus: Int32?) -> Int? {
        waitStatus.map { ($0 & 0x7f) == 0 ? Int(($0 >> 8) & 0xff) : 128 + Int($0 & 0x7f) }
    }

    public static func tail(of url: URL?, maximumBytes: Int = 16 * 1024) -> String {
        guard maximumBytes > 0, let url, let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        let length = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: length > maximumBytes ? length - UInt64(maximumBytes) : 0)
        return String(decoding: (try? file.read(upToCount: maximumBytes)) ?? Data(), as: UTF8.self)
    }

    /// Retain the newest 20 reports across reconnects and restarts; SSH logs have their own lifetime.
    @discardableResult public func save(in directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // UUID filenames also prevent a remote identifier from becoming a path component.
        let url = directory.appendingPathComponent("\(UUID().uuidString).terminal-context.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        // Create with private permissions before any content is written.
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.write(contentsOf: data)
            try file.synchronize()
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
        let reports = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0 != url && $0.lastPathComponent.hasSuffix(".terminal-context.json") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in reports.dropFirst(19) { try? manager.removeItem(at: old) }
        return url
    }
}
