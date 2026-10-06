import Foundation

/// Keep the saved name and the machine identity separate, including in historical records.
public struct HostDisplayName: Equatable {
    public let name: String
    public let hostname: String?

    public init(name: String, hostname: String?) {
        self.name = name
        let value = hostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.hostname = value.isEmpty ? nil : value
    }

    public var full: String { name + suffix(compact: false) }
    public var compact: String { name + suffix(compact: true) }
    public func suffix(compact: Bool) -> String {
        guard let hostname else { return "" }
        let value = compact && hostname.count > 6 ? "..." + hostname.suffix(6) : hostname
        return "(\(value))"
    }
}

public extension Host {
    var displayName: HostDisplayName {
        HostDisplayName(name: name, hostname: systemProfile?.hostname?.isEmpty == false ? systemProfile?.hostname : address)
    }
    var folderPath: String { group.isEmpty ? L10n.tr("All Hosts") : L10n.tr("All Hosts/") + group }
}
