import Foundation

public enum HostSort: String, CaseIterable, Identifiable {
    case folders, name, created, login
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .folders: return L10n.tr("Folder name")
        case .name: return L10n.tr("Server name")
        case .created: return L10n.tr("Date added")
        case .login: return L10n.tr("Last login")
        }
    }
}

public enum HostTree {
    public static func normalize(_ path: String) throws -> String {
        let parts = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\n") }) else {
            throw BozhouError.invalid(L10n.tr("Folder paths support up to 32 levels. Names cannot be . or .., or contain newlines."))
        }
        return parts.joined(separator: "/")
    }
    public static func ancestors(_ path: String) -> [String] {
        let parts = path.split(separator: "/")
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }
    public static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    public static func contains(_ path: String, in folder: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }
    public static func sorted(_ hosts: [Host], by sort: HostSort, ascending: Bool) -> [Host] {
        hosts.sorted { a, b in
            let order: ComparisonResult
            switch sort {
            case .created: order = a.createdAt.compare(b.createdAt)
            case .login: order = (a.lastLoginAt ?? .distantPast).compare(b.lastLoginAt ?? .distantPast)
            case .folders:
                let groupOrder = a.group.localizedStandardCompare(b.group)
                order = groupOrder == .orderedSame ? a.name.localizedStandardCompare(b.name) : groupOrder
            case .name: order = a.name.localizedStandardCompare(b.name)
            }
            if order == .orderedSame { return a.id.uuidString < b.id.uuidString }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
