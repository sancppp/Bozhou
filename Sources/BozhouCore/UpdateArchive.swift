import Foundation

public enum UpdateArchive {
    private static var invalid: BozhouError { .invalid(L10n.tr("The update archive is invalid or unsafe")) }
    /// Check central AND local names before handing the ZIP to ditto. ZIP64, encrypted entries,
    /// links, traversal and oversized expansion are rejected.
    public static func validate(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22, data.count <= UpdateDownload.maximumBytes else { throw invalid }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw invalid }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int { try u16(offset) | u16(offset + 2) << 16 }
        func checkExtra(_ start: Int, _ length: Int) throws {
            var offset = start
            guard start + length <= data.count else { throw invalid }
            while offset < start + length {
                guard offset + 4 <= start + length else { throw invalid }
                let kind = try u16(offset), size = try u16(offset + 2)
                // Alternative Unicode path fields could override the checked file name.
                guard kind != 0x0001, kind != 0x7075, offset + 4 + size <= start + length else { throw invalid }
                offset += 4 + size
            }
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(offset) == 0x06054b50, try offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw invalid }
        let count = try u16(end + 10), directorySize = try u32(end + 12), directory = try u32(end + 16)
        guard count > 0, count < 65535, try u16(end + 8) == count, directory + directorySize == end else { throw invalid }
        var cursor = directory, expanded = 0, names = Set<String>(), intervals: [Range<Int>] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try u32(cursor) == 0x02014b50 else { throw invalid }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20), size = try u32(cursor + 24)
            let nameSize = try u16(cursor + 28), extraSize = try u16(cursor + 30), commentSize = try u16(cursor + 32)
            let mode = try u32(cursor + 38) >> 16, local = try u32(cursor + 42)
            let next = cursor + 46 + nameSize + extraSize + commentSize
            guard next <= end, nameSize > 0, flags & 1 == 0, [0, 8].contains(method),
                  [0, 0o100000, 0o040000].contains(mode & 0o170000), try u16(cursor + 34) == 0 else { throw invalid }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard let name = String(data: nameData, encoding: .utf8), safeName(name),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid }
            try checkExtra(cursor + 46 + nameSize, extraSize)
            expanded += size
            guard expanded <= 1024 * 1024 * 1024, size <= UpdateDownload.maximumBytes else { throw invalid }
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method else { throw invalid }
            let localNameSize = try u16(local + 26), localExtraSize = try u16(local + 28)
            let content = local + 30 + localNameSize + localExtraSize
            guard localNameSize == nameSize, content + compressed <= directory,
                  data.subdata(in: local + 30..<local + 30 + localNameSize) == nameData else { throw invalid }
            try checkExtra(local + 30 + localNameSize, localExtraSize)
            intervals.append(local..<content + compressed)
            cursor = next
        }
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sorted.count where sorted[index - 1].upperBound > sorted[index].lowerBound { throw invalid }
        guard cursor == end, names.contains("泊舟.app/contents/info.plist"),
              names.contains("泊舟.app/contents/macos/bozhou") else { throw invalid }
    }
    public static func safeName(_ name: String) -> Bool {
        guard !name.contains("\\"), !name.contains("\0"), !name.contains(":"),
              name.hasPrefix("泊舟.app/") || name.hasPrefix("__MACOSX/") else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.dropLast().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
            parts.last != "." && parts.last != ".."
    }
    public static func extract(_ archive: URL, into directory: URL) throws -> URL {
        try validate(archive)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw invalid }
            for case let file as URL in entries {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw invalid }
            }
            return directory.appendingPathComponent("泊舟.app")
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public static func verifyApp(_ url: URL, version: String? = nil) throws {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.bozhou.ssh",
              info["CFBundleExecutable"] as? String == "Bozhou",
              version == nil || info["CFBundleShortVersionString"] as? String == version else { throw invalid }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        // Read Mach-O headers directly; updating must not require Xcode command-line tools.
        let handle = try FileHandle(forReadingFrom: url.appendingPathComponent("Contents/MacOS/Bozhou"))
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, little: Bool) -> UInt32? {
            guard offset + 4 <= header.count else { return nil }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << (little ? $1 * 8 : (3 - $1) * 8) }
        }
        if word(0, little: true) == 0xfeedfacf, word(4, little: true) == 0x0100000c { return }
        if let magic = word(0, little: false), [0xcafebabe, 0xcafebabf].contains(magic),
           let count = word(4, little: false), count <= 32 {
            let stride = magic == 0xcafebabf ? 32 : 20
            for index in 0..<Int(count) where word(8 + index * stride, little: false) == 0x0100000c { return }
        }
        throw invalid
    }
    public static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                throw BozhouError.invalid(L10n.tr("Update verification or installation failed"))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BozhouError.invalid(L10n.tr("Update verification or installation failed")) }
    }
}

public enum AppReplacement {
    /// The new bundle must be staged on the same volume. Retain the old bundle on success,
    /// restore it on verification/launch failure. Never touch the user's data directory.
    @discardableResult
    public static func commit(staged: URL, target: URL, validate: (URL) throws -> Void,
                              launch: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let backup = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".backup-" + UUID().uuidString)
        try validate(staged)
        guard fm.fileExists(atPath: target.path), staged != target else { throw BozhouError.invalid(L10n.tr("Installed Bozhou app was not found")) }
        try fm.moveItem(at: target, to: backup)
        var installed = false
        do {
            try fm.moveItem(at: staged, to: target); installed = true
            try validate(target)
            try launch(target)
            return backup
        } catch {
            if installed { try? fm.removeItem(at: target) }
            do { try fm.moveItem(at: backup, to: target) }
            catch { throw BozhouError.storage(L10n.tr("Restore the previous app from \(backup.path)")) }
            throw error
        }
    }
}
