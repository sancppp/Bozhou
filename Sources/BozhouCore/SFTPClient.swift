import Foundation
import Darwin

public struct RemoteFile: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var size: UInt64
    public var permissions: UInt32
    public var modified: Date?
    public var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    public var isSymbolicLink: Bool { permissions & 0o170000 == 0o120000 }
}

struct Packet {
    var data: Data = Data()
    var index = 0
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint(_ value: UInt32) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    mutating func long(_ value: UInt64) { uint(UInt32(value >> 32)); uint(UInt32(truncatingIfNeeded: value)) }
    mutating func bytes(_ value: Data) { uint(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func readByte() throws -> UInt8 {
        guard index < data.count else { throw BozhouError.protocolError("SFTP 响应被截断") }
        defer { index += 1 }; return data[index]
    }
    mutating func readUInt() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try readByte()) }
        return value
    }
    mutating func readLong() throws -> UInt64 { let high = try readUInt(); return UInt64(high) << 32 | UInt64(try readUInt()) }
    mutating func readBytes() throws -> Data {
        let count = Int(try readUInt())
        guard count <= data.count - index else { throw BozhouError.protocolError("SFTP 字段长度无效") }
        defer { index += count }; return data.subdata(in: index..<(index + count))
    }
    mutating func readString() throws -> String { String(decoding: try readBytes(), as: UTF8.self) }
    mutating func attributes(name: String) throws -> RemoteFile {
        let flags = try readUInt()
        let size: UInt64 = flags & 1 != 0 ? try readLong() : 0
        if flags & 2 != 0 { _ = try readUInt(); _ = try readUInt() }
        let permissions: UInt32 = flags & 4 != 0 ? try readUInt() : 0
        var modified: Date?
        if flags & 8 != 0 { _ = try readUInt(); modified = Date(timeIntervalSince1970: Double(try readUInt())) }
        if flags & 0x80000000 != 0 {
            let count = try readUInt()
            guard count < 4096 else { throw BozhouError.protocolError("SFTP 属性数量异常") }
            for _ in 0..<count { _ = try readBytes(); _ = try readBytes() }
        }
        return RemoteFile(name: name, size: size, permissions: permissions, modified: modified)
    }
}

/// Blocking pipe IO stays on a dedicated dispatch queue, never the main/cooperative executor.
private final class SFTPTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bozhou.sftp", qos: .userInitiated)
    private let stateLock = NSLock()
    private var cancelled = false
    private var diagnostic = Data()
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let launch: SSHLaunch
    init(launch: SSHLaunch) { self.launch = launch }
    deinit { cancel(); launch.cleanup() }
    func cancel() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
        if process.isRunning { process.terminate() }
    }
    private func check() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        if cancelled { throw BozhouError.cancelled }
    }
    private func startProcess() throws {
        // Serialize launch with cancellation so cancel cannot miss a not-yet-running process.
        stateLock.lock(); defer { stateLock.unlock() }
        if cancelled { throw BozhouError.cancelled }
        try process.run()
    }
    private func failure() -> BozhouError {
        stateLock.lock(); defer { stateLock.unlock() }
        let text = String(decoding: diagnostic, as: UTF8.self) + "\n" +
            (launch.logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
        return .connection("SFTP 连接已关闭。请检查网络、认证与主机指纹。\n\(text)")
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.check()
                    self.process.executableURL = URL(fileURLWithPath: self.launch.executable)
                    self.process.arguments = self.launch.arguments
                    self.process.environment = self.launch.environment
                    self.process.standardInput = self.input
                    self.process.standardOutput = self.output
                    self.process.standardError = self.errors
                    self.errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        guard let self else { return }
                        self.stateLock.lock()
                        self.diagnostic.append(data)
                        if self.diagnostic.count > 8192 { self.diagnostic.removeFirst(self.diagnostic.count - 8192) }
                        self.stateLock.unlock()
                    }
                    try self.startProcess()
                    for fd in [self.input.fileHandleForWriting.fileDescriptor, self.output.fileHandleForReading.fileDescriptor] {
                        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    }
                    // A closed remote channel must become an error, never SIGPIPE the application.
                    _ = fcntl(self.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func exchange(_ body: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try self.check()
                        let deadline = Date().addingTimeInterval(60)
                        var frame = Packet(); frame.bytes(body)
                        try self.write(frame.data, deadline: deadline)
                        var header = Packet(data: try self.read(4, deadline: deadline))
                        let size = Int(try header.readUInt())
                        guard (1...1_048_576).contains(size) else { throw BozhouError.protocolError("SFTP 数据包过大或无效") }
                        continuation.resume(returning: try self.read(size, deadline: deadline))
                    } catch {
                        self.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
    private func wait(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            try check()
            if Date() > deadline { throw BozhouError.connection("SFTP 操作超时（60 秒），连接已关闭") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                throw failure()
            }
            if result < 0 && errno != EINTR { throw failure() }
        }
    }
    private func read(_ count: Int, deadline: Date) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        let fd = output.fileHandleForReading.fileDescriptor
        while offset < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n == 0 { throw failure() }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure() }
            offset += n
        }
        return Data(bytes)
    }
    private func write(_ data: Data, deadline: Date) throws {
        var offset = 0
        let fd = input.fileHandleForWriting.fileDescriptor
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure() }
            guard n > 0 else { throw failure() }; offset += n
        }
    }
}

public actor SFTPClient {
    private let transport: SFTPTransport
    private var nextID: UInt32 = 0
    public init(launch: SSHLaunch) { transport = SFTPTransport(launch: launch) }
    public nonisolated func cancel() { transport.cancel() }
    public func connect() async throws -> String {
        try await transport.start()
        var initPacket = Packet(); initPacket.byte(1); initPacket.uint(3)
        var response = Packet(data: try await transport.exchange(initPacket.data))
        guard try response.readByte() == 2, try response.readUInt() == 3 else {
            transport.cancel(); throw BozhouError.protocolError("服务器不支持 SFTP v3")
        }
        var path = Packet(); path.string(".")
        var (_, reply) = try await request(16, path, expecting: 104)
        guard try reply.readUInt() > 0 else { throw BozhouError.protocolError("无法获取远程目录") }
        return try reply.readString()
    }
    public func list(_ path: String) async throws -> [RemoteFile] {
        var body = Packet(); body.string(path)
        var (_, reply) = try await request(11, body, expecting: 102)
        let handle = try reply.readBytes()
        var result: [RemoteFile] = []
        do {
            while true {
                try Task.checkCancellation()
                var body = Packet(); body.bytes(handle)
                var (type, response) = try await request(12, body, expecting: 104, eofAllowed: true)
                if type == 101 { break }
                let count = try response.readUInt()
                guard count <= 100_000 else { throw BozhouError.protocolError("目录条目数量异常") }
                for _ in 0..<count {
                    let name = try response.readString()
                    _ = try response.readString()
                    let entry = try response.attributes(name: name)
                    if name != "." && name != ".." { result.append(entry) }
                }
                guard result.count <= 100_000 else { throw BozhouError.protocolError("目录超过 100000 个文件，请缩小范围") }
            }
            try await close(handle)
        } catch { try? await close(handle); throw error }
        return result.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func mkdir(_ path: String) async throws {
        var body = Packet(); body.string(path); body.uint(0)
        _ = try await request(14, body, expecting: 101)
    }
    public func rename(_ from: String, to: String) async throws {
        var body = Packet(); body.string(from); body.string(to)
        _ = try await request(18, body, expecting: 101)
    }
    public func remove(_ path: String, directory: Bool) async throws {
        var body = Packet(); body.string(path)
        _ = try await request(directory ? 15 : 13, body, expecting: 101)
    }
    public func upload(local: URL, remote: String, progress: @Sendable (UInt64, UInt64) -> Void) async throws {
        let input = try FileHandle(forReadingFrom: local); defer { try? input.close() }
        let total = UInt64((try local.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        // EXCL protects existing remote files. The UI deliberately does not overwrite.
        let handle = try await open(remote, flags: 2 | 8 | 32)
        var offset: UInt64 = 0
        do {
            while let data = try input.read(upToCount: 32768), !data.isEmpty {
                try Task.checkCancellation()
                var body = Packet(); body.bytes(handle); body.long(offset); body.bytes(data)
                _ = try await request(6, body, expecting: 101)
                offset += UInt64(data.count); progress(offset, total)
            }
            try await close(handle); progress(total, total)
        } catch {
            try? await close(handle)
            // A partial upload has its requested name; reported explicitly by UI on failure.
            throw error
        }
    }
    public func download(remote: String, local: URL, total: UInt64, progress: @Sendable (UInt64, UInt64) -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: local.path) else { throw BozhouError.invalid("本地文件已存在，请选择其他名称") }
        let partial = local.deletingLastPathComponent().appendingPathComponent(".bozhou-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BozhouError.invalid("无法创建下载文件")
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        let output = try FileHandle(forWritingTo: partial); defer { try? output.close() }
        let handle = try await open(remote, flags: 1)
        var offset: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                var body = Packet(); body.bytes(handle); body.long(offset); body.uint(32768)
                var (type, response) = try await request(5, body, expecting: 103, eofAllowed: true)
                if type == 101 { break }
                let bytes = try response.readBytes()
                guard !bytes.isEmpty else { throw BozhouError.protocolError("服务器返回空数据块") }
                try output.write(contentsOf: bytes)
                offset += UInt64(bytes.count); progress(offset, total)
            }
            try output.synchronize()
            try await close(handle)
            try FileManager.default.moveItem(at: partial, to: local)
        } catch { try? await close(handle); throw error }
    }
    /// Relay a bounded 32 KiB block between authenticated SFTP transports; no local staging file.
    /// A unique remote temporary file is renamed only after both handles close successfully.
    public func copy(remote: String, to destination: SFTPClient, path: String, total: UInt64,
                     progress: @Sendable (UInt64, UInt64) -> Void) async throws {
        let sourceHandle = try await open(remote, flags: 1)
        let partial = path + ".bozhou-\(UUID().uuidString).part"
        var targetHandle: Data?
        do {
            let handle = try await destination.open(partial, flags: 2 | 8 | 32)
            targetHandle = handle
            var offset: UInt64 = 0
            progress(0, total)
            while true {
                try Task.checkCancellation()
                var body = Packet(); body.bytes(sourceHandle); body.long(offset); body.uint(32768)
                var (type, reply) = try await request(5, body, expecting: 103, eofAllowed: true)
                if type == 101 { break }
                let bytes = try reply.readBytes()
                guard !bytes.isEmpty else { throw BozhouError.protocolError("服务器返回空数据块") }
                try await destination.writeChunk(handle: handle, offset: offset, bytes: bytes)
                offset += UInt64(bytes.count); progress(offset, max(total, offset))
            }
            try await close(sourceHandle)
            try await destination.close(handle)
            targetHandle = nil
            try Task.checkCancellation()
            try await destination.rename(partial, to: path)
            progress(offset, offset)
        } catch {
            try? await close(sourceHandle)
            if let targetHandle { try? await destination.close(targetHandle) }
            try? await destination.remove(partial, directory: false)
            throw BozhouError.connection("\(error.localizedDescription)\n传输未完成；如连接已断开，请检查临时文件：\(partial)")
        }
    }
    private func writeChunk(handle: Data, offset: UInt64, bytes: Data) async throws {
        var body = Packet(); body.bytes(handle); body.long(offset); body.bytes(bytes)
        _ = try await request(6, body, expecting: 101)
    }
    private func open(_ path: String, flags: UInt32) async throws -> Data {
        var body = Packet(); body.string(path); body.uint(flags); body.uint(0)
        var (_, reply) = try await request(3, body, expecting: 102)
        return try reply.readBytes()
    }
    private func close(_ handle: Data) async throws {
        var body = Packet(); body.bytes(handle); _ = try await request(4, body, expecting: 101)
    }
    private func request(_ type: UInt8, _ body: Packet, expecting: UInt8, eofAllowed: Bool = false) async throws -> (UInt8, Packet) {
        nextID &+= 1
        let id = nextID
        var packet = Packet(); packet.byte(type); packet.uint(id); packet.data.append(body.data)
        var reply = Packet(data: try await transport.exchange(packet.data))
        let responseType = try reply.readByte()
        guard try reply.readUInt() == id else { throw BozhouError.protocolError("SFTP 请求编号不匹配") }
        if responseType == 101 {
            let code = try reply.readUInt()
            if code == 0 && expecting == 101 { return (responseType, reply) }
            if code == 1 && eofAllowed { return (responseType, reply) }
            let message = try reply.readString()
            let meanings: [UInt32: String] = [1: "文件结束", 2: "文件不存在", 3: "没有访问权限", 4: "操作失败（文件可能已存在）", 8: "服务器不支持该操作"]
            throw BozhouError.connection("SFTP：\(meanings[code] ?? "错误 \(code)")\n\(message)")
        }
        guard responseType == expecting else { throw BozhouError.protocolError("非预期的 SFTP 响应：\(responseType)") }
        return (responseType, reply)
    }
}
