import Foundation
import CryptoKit

/// Provider-neutral persisted data. CLI implementations live in independent plugin modules.
public struct MetadataBinding: Codable, Equatable, Sendable {
    public var resourceID = ""
    public var region = ""
    public var accountID = ""
    public var environment = ""
    public init() {}
}

public struct MetadataLayout: Codable, Equatable, Sendable {
    public var hidden: Set<String> = []
    public var order: [String] = []
    public init() {}

    public func arrange(_ fields: [MetadataField], includeHidden: Bool = false) -> [MetadataField] {
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return fields.filter { includeHidden || !hidden.contains($0.id) }.sorted {
            let a = ranks[$0.id] ?? Int.max, b = ranks[$1.id] ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
    public mutating func move(_ id: String, by distance: Int, fields: [MetadataField]) {
        var ids = arrange(fields, includeHidden: true).map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + distance) else { return }
        ids.swapAt(index, index + distance)
        // Keep preferences for fields absent from this particular host.
        order = ids + order.filter { !ids.contains($0) }
    }
}

public struct MetadataField: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public init(id: String, title: String, value: String) {
        self.id = id; self.title = title; self.value = value
    }
}

public struct MetadataSnapshot: Codable, Equatable, Sendable {
    public var providerID: String
    public var subjectKey: String
    public var resourceID: String
    public var region: String
    public var accountID: String
    public var environment: String
    public var collectedAt: Date
    public var fields: [MetadataField]
    public var notices: [String]
    public init(providerID: String, subjectKey: String, resourceID: String, region: String, accountID: String,
                environment: String, fields: [MetadataField], notices: [String], collectedAt: Date = Date()) {
        self.providerID = providerID; self.subjectKey = subjectKey; self.resourceID = resourceID
        self.region = region; self.accountID = accountID; self.environment = environment
        self.fields = fields; self.notices = notices; self.collectedAt = collectedAt
    }
}

/// Deliberately excludes passwords, SSH environment variables and private key paths.
public struct MetadataSubject: Equatable, Sendable {
    public let hostID: UUID
    public let name: String
    public let hostname: String
    public let address: String
    public let binding: MetadataBinding
    public init(host: Host, providerID: String) {
        hostID = host.id; name = host.name; hostname = host.systemProfile?.hostname ?? ""
        address = host.address; binding = host.metadataBindings[providerID] ?? MetadataBinding()
    }
    public var key: String {
        let parts = [name, hostname, address, binding.resourceID, binding.region, binding.accountID, binding.environment]
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Host {
    public func metadataSnapshot(for providerID: String) -> MetadataSnapshot? {
        guard let snapshot = metadataSnapshots[providerID],
              snapshot.providerID == providerID,
              snapshot.subjectKey == MetadataSubject(host: self, providerID: providerID).key else { return nil }
        return snapshot
    }
}
