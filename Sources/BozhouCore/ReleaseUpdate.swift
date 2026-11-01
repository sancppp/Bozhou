import Foundation
import CryptoKit

public struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    private let parts: [Int]
    public var description: String { parts.map(String.init).joined(separator: ".") }
    public init?(_ value: String) {
        var value = value
        if value.hasPrefix("release/") { value.removeFirst(8) }
        if value.hasPrefix("v") { value.removeFirst() }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct ReleaseUpdate: Sendable {
    public let version: ReleaseVersion
    public let notes: String
    public let page: URL
    public let archive: URL
    public let checksums: URL
    public let filename: String
    public let size: Int64

    public static let endpoint = URL(string: "https://api.github.com/repos/sancppp/Bozhou/releases/latest")!
    private struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int64 }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }
    public static func parse(_ data: Data, current: ReleaseVersion) throws -> ReleaseUpdate? {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw BozhouError.invalid(L10n.tr("GitHub returned invalid release information")) }
        guard !payload.draft, !payload.prerelease, let version = ReleaseVersion(payload.tag_name), version > current else { return nil }
        let filename = "Bozhou-\(version)-macOS-arm64.zip"
        guard let archive = payload.assets.first(where: { $0.name == filename }),
              let sums = payload.assets.first(where: { $0.name == "SHA256SUMS" }),
              archive.size > 0, archive.size <= UpdateDownload.maximumBytes,
              sums.size > 0, sums.size <= 1024 * 1024,
              validAsset(archive.browser_download_url), validAsset(sums.browser_download_url),
              payload.html_url.scheme == "https", payload.html_url.host == "github.com",
              payload.html_url.path.hasPrefix("/sancppp/Bozhou/releases/") else {
            throw BozhouError.invalid(L10n.tr("This release has no supported Apple Silicon update with SHA-256 checksums"))
        }
        return ReleaseUpdate(version: version, notes: payload.body ?? "", page: payload.html_url,
                             archive: archive.browser_download_url, checksums: sums.browser_download_url,
                             filename: filename, size: archive.size)
    }
    private static func validAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
            url.path.hasPrefix("/sancppp/Bozhou/releases/download/")
    }
    public static func checksum(_ text: String, filename: String) throws -> String {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == filename,
                  fields[0].count == 64, fields[0].allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return fields[0].lowercased()
        }
        guard matches.count == 1 else { throw BozhouError.invalid(L10n.tr("Missing or ambiguous SHA-256 checksum")) }
        return matches[0]
    }
    public static func verify(file: URL, sha256: String) throws {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw BozhouError.invalid(L10n.tr("Update checksum mismatch. Download the update again."))
        }
    }
}

/// Downloads stream to a temporary file; cancellation and byte limits also cover chunked responses.
public final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let maximumBytes: Int64 = 512 * 1024 * 1024
    private let limit: Int64
    private let progress: @Sendable (Double) -> Void
    public init(limit: Int64 = maximumBytes, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.limit = limit; self.progress = progress
    }
    public func fetch(_ url: URL, to destination: URL) async throws -> Int {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Bozhou-macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (file, response) = try await session.download(for: request, delegate: self)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return http.statusCode }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw BozhouError.invalid(L10n.tr("Update download exceeded its size limit")) }
        try FileManager.default.moveItem(at: file, to: destination)
        return http.statusCode
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel(); return }
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts = ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        completionHandler(request.url?.scheme == "https" && hosts.contains(request.url?.host ?? "") ? request : nil)
    }
}
