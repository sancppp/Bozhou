import Foundation
import OSLog

public enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case info, warning, error
    public var id: String { rawValue }
    public var title: String {
        switch self { case .info: return "信息"; case .warning: return "警告"; case .error: return "错误" }
    }
}

public struct LogEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var level: LogLevel
    public var category: String
    public var message: String

    public func matches(search: String, level: LogLevel?, category: String) -> Bool {
        (level == nil || self.level == level) && (category.isEmpty || self.category == category) &&
        (search.isEmpty || "\(message) \(self.category)".localizedCaseInsensitiveContains(search))
    }
}

/// Unified macOS logging plus a bounded, structured local archive for the in-app viewer.
public final class AppLog: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "dev.bozhou.ssh", category: "lifecycle")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public let url: URL
    public init(paths: AppPaths) { url = paths.logs.appendingPathComponent("bozhou.log") }

    public func write(_ text: String, level: LogLevel = .info, category: String = "应用") {
        let message = String(text.replacingOccurrences(of: "\n", with: " ").prefix(4000))
        switch level {
        case .info: logger.info("\(category, privacy: .public): \(message)")
        case .warning: logger.warning("\(category, privacy: .public): \(message)")
        case .error: logger.error("\(category, privacy: .public): \(message)")
        }
        lock.lock(); defer { lock.unlock() }
        guard var data = try? encoder.encode(LogEntry(level: level, category: category, message: message)) else { return }
        data.append(10)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) }
            catch { logger.error("日志写入失败：\(error.localizedDescription)") }
        }
    }

    public func entries() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        let legacyDate = ISO8601DateFormatter()
        return [url.appendingPathExtension("1"), url].flatMap { file -> [LogEntry] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                if let entry = try? decoder.decode(LogEntry.self, from: Data(line.utf8)) { return entry }
                // Retain v1 log records during upgrades.
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2, let date = legacyDate.date(from: String(fields[0])) else { return nil }
                return LogEntry(date: date, level: .info, category: "旧版", message: String(fields[1]))
            }
        }.suffix(10000).reversed()
    }
}
