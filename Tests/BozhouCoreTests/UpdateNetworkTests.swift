import Foundation
import BozhouCore

enum UpdateNetworkTests {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bozhou-update-network-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["BOZHOU_PYTHON"] ?? "python3", "-u", "Tests/update_http_fixture.py"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
        let output = root.appendingPathComponent("ok")
        let code = try await UpdateDownload().fetch(url("ok"), to: output)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(try Data(contentsOf: output).count, 65536)
        let missing = root.appendingPathComponent("missing")
        let missingCode = try await UpdateDownload().fetch(url("missing"), to: missing)
        XCTAssertEqual(missingCode, 404)
        XCTAssertTrue(!fm.fileExists(atPath: missing.path))
        do {
            _ = try await UpdateDownload(limit: 1024).fetch(url("large"), to: root.appendingPathComponent("large"))
            fail("Oversized update was accepted")
        } catch {}
        let cancelledFile = root.appendingPathComponent("cancelled")
        let slowURL = url("slow")
        let task = Task { try await UpdateDownload().fetch(slowURL, to: cancelledFile) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; fail("Cancelled download completed") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertTrue(!fm.fileExists(atPath: cancelledFile.path))
        let search = Task {
            await TextSearch.background { TextSearch.ranges(in: String(repeating: "needle ", count: 1_000_000), query: "needle") }
        }
        search.cancel()
        let cancelledHits = await search.value
        XCTAssertTrue(cancelledHits.isEmpty)
        print("PASS URLSession streaming, HTTP errors, size limit, cancellation and search cancellation")
    }

    /// Explicit opt-in smoke test of the production transport against the public release.
    static func verifyPublicRelease(at directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appendingPathComponent("release.json")
        let code = try await UpdateDownload(limit: 2 * 1024 * 1024).fetch(ReleaseUpdate.endpoint, to: metadata)
        guard code == 200 else { throw BozhouError.invalid("Public release API HTTP \(code)") }
        let release = try XCTUnwrap(ReleaseUpdate.parse(Data(contentsOf: metadata), current: ReleaseVersion("0.0.0")!))
        let sums = directory.appendingPathComponent("SHA256SUMS")
        let archive = directory.appendingPathComponent(release.filename)
        let sumsCode = try await UpdateDownload(limit: 1024 * 1024).fetch(release.checksums, to: sums)
        let zipCode = try await UpdateDownload(limit: release.size).fetch(release.archive, to: archive)
        guard sumsCode == 200, zipCode == 200 else { throw BozhouError.invalid("Public release asset HTTP \(sumsCode)/\(zipCode)") }
        let hash = try ReleaseUpdate.checksum(String(contentsOf: sums), filename: release.filename)
        try ReleaseUpdate.verify(file: archive, sha256: hash)
        let app = try UpdateArchive.extract(archive, into: directory.appendingPathComponent("extracted"))
        try UpdateArchive.verifyApp(app, version: release.version.description)
        print("PASS public GitHub release \(release.version), asset download, SHA-256, ZIP, bundle and arm64 signature")
    }
}
