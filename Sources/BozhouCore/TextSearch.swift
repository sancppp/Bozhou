import Foundation

/// Literal, Unicode-aware matching shared by filtering and native/SwiftUI highlights.
public enum TextSearch {
    public struct Request: Hashable {
        public let text: String
        public let query: String
        public init(text: String, query: String) { self.text = text; self.query = query }
    }

    /// Detached work never runs on the main actor; cancellation follows the owning view task.
    public static func background<T>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    public static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var result: [NSRange] = []
        var start = 0
        while start < ns.length {
            if Task.isCancelled { return [] }
            let range = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: NSRange(location: start, length: ns.length - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range)
            start = NSMaxRange(range)
        }
        return result
    }

    public static func contains(_ text: String, query: String) -> Bool {
        query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public static func matches(_ item: Interaction, name: HostDisplayName, query: String) -> Bool {
        [name.full, item.command, item.output, item.shell].contains { contains($0, query: query) }
    }

    /// Show the first hit even if it is deep inside a long output.
    public static func excerpt(_ text: String, query: String, context: Int = 48) -> String? {
        guard !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end].replacingOccurrences(of: "\n", with: " ")
            + (end == text.endIndex ? "" : "…")
    }
}
