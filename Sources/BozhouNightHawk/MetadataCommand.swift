import Foundation
import Darwin
import BozhouCore

/// NightHawk's CLI/SSO boundary. No shell, no interactive stdin, bounded pipes and wall time.
public struct MetadataCommand: MetadataCommandRunning {
    private static let pacer = MetadataCommandPacer()
    public var timeout: TimeInterval
    public var outputLimit: Int
    public init(timeout: TimeInterval = 20, outputLimit: Int = 8 * 1024 * 1024) {
        self.timeout = timeout; self.outputLimit = outputLimit
    }
    public static func resolve(_ configured: String) throws -> String {
        let path = (configured.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if !path.isEmpty {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw MetadataFailure.message(L10n.tr("Choose an executable NightHawk CLI file."))
            }
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [home + "/.local/tools", home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        for directory in directories {
            let path = directory + "/nighthawk-cli"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw MetadataFailure.message(L10n.tr("NightHawk CLI was not found. Install it locally or choose its executable in Settings."))
    }

    public func run(executable: String, arguments: [String]) async throws -> Data {
        if arguments.first == "resource" { try await Self.pacer.waitForTurn() }
        let cancellation = CommandCancellation()
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result { try execute(executable, arguments, cancellation) })
                    }
                }
            } onCancel: { cancellation.cancel() }
        } catch MetadataFailure.rateLimited(let id) {
            await Self.pacer.pause()
            throw MetadataFailure.rateLimited(id)
        } catch { throw error }
    }
    private func execute(_ executable: String, _ arguments: [String], _ cancellation: CommandCancellation) throws -> Data {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["NIGHTHAWK_AUTH_MODE"] = "sso_exchange"
        environment["NIGHTHAWK_SKILL_NAME"] = "nighthawk-resource"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = [URL(fileURLWithPath: executable).deletingLastPathComponent().path,
                               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                               environment["PATH"] ?? ""].joined(separator: ":")
        process.environment = environment
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
        defer {
            for handle in handles { try? handle.close() }
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { throw MetadataFailure.message(L10n.tr("Could not start NightHawk CLI. Check its executable path.")) }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        defer {
            // SIGKILL is restricted to the still-running child owned by this query.
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var data = Data(), diagnostics = Data(), byteCount = 0, endedAt: TimeInterval?, eof: Set<Int> = []
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let now = ProcessInfo.processInfo.systemUptime
            if now - started > timeout { throw MetadataFailure.message(L10n.tr("NightHawk query timed out. Try refreshing again.")) }
            for (index, handle) in handles.enumerated() where !eof.contains(index) {
                // Limit each drain so continuously writing children cannot starve cancellation.
                for _ in 0..<32 {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count == 0 { eof.insert(index); break }
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { break }
                        throw MetadataFailure.message(L10n.tr("Could not read NightHawk CLI output."))
                    }
                    byteCount += count
                    guard byteCount <= outputLimit else { throw MetadataFailure.message(L10n.tr("NightHawk output exceeded the size limit.")) }
                    if index == 0 { data.append(contentsOf: buffer.prefix(count)) }
                    else if diagnostics.count < 16384 { diagnostics.append(contentsOf: buffer.prefix(min(count, 16384 - diagnostics.count))) }
                }
            }
            if !process.isRunning {
                if endedAt == nil { endedAt = now }
                if eof.count == 2 || now - endedAt! > 0.25 { break }
            }
            var descriptors = handles.enumerated().filter { !eof.contains($0.offset) }.map {
                pollfd(fd: $0.element.fileDescriptor, events: Int16(POLLIN), revents: 0)
            }
            if descriptors.isEmpty { usleep(20_000) }
            else { _ = poll(&descriptors, nfds_t(descriptors.count), 20) }
        }
        if process.terminationStatus != 0 {
            // Extract only diagnostic identifiers, never echo arbitrary CLI output or credentials.
            let text = String(decoding: data.prefix(16384) + diagnostics, as: UTF8.self)
            func identifier(_ pattern: String) -> String? {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            }
            let code = identifier(#"code["\s]*[=:]\s*([0-9]{1,6})"#)
            let logID = identifier(#"log_?[iI]d["\s]*[=:]\s*"?([a-zA-Z0-9_-]{8,128})"#)
            if code == "429" { throw MetadataFailure.rateLimited(logID) }
            var message = code == "404" ? L10n.tr("Resource not found in the selected NightHawk environment.")
                : L10n.tr("NightHawk CLI failed. Check local login, permissions and the selected environment, then refresh.")
            if let code { message += "\n" + L10n.tr("Error code: \(code)") }
            if let logID { message += "\n" + L10n.tr("Request ID: \(logID)") }
            throw MetadataFailure.message(message)
        }
        return data
    }
}

private actor MetadataCommandPacer {
    private var nextRequest: TimeInterval = 0
    func waitForTurn() async throws {
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextRequest { nextRequest = now + 1.2; return }
            try await Task.sleep(for: .seconds(nextRequest - now))
        }
    }
    func pause() { nextRequest = max(nextRequest, ProcessInfo.processInfo.systemUptime + 60) }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
