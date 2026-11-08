import Foundation

/// Builds an allowlisted index away from the UI. Queries reuse it until observations or settings change.
public actor HostSearchIndex {
    private var revision: Int?
    private var documents: [(UUID, [String])] = []
    public init() {}

    public func matches(hosts: [Host], enabledProviders: Set<String>, revision: Int, query: String) -> Set<UUID> {
        if self.revision != revision {
            let names = Dictionary(hosts.map { ($0.id, $0.displayName.full) }, uniquingKeysWith: { first, _ in first })
            var documents: [(UUID, [String])] = []
            for host in hosts {
                guard !Task.isCancelled else { return [] }
                var fields = [host.name, host.displayName.full, host.address, "\(host.address):\(host.port)",
                              host.username, host.tags, host.folderPath, host.notes, host.authentication.title]
                fields += host.jumpHosts.compactMap { names[$0] }
                if let date = host.lastLoginAt { fields.append(L10n.date(date)) }
                if let profile = host.systemProfile {
                    fields += [profile.hostname ?? "", profile.operatingSystem, profile.kernel, profile.cpuSummary, profile.memory]
                }
                for provider in enabledProviders.sorted() {
                    guard let snapshot = host.metadataSnapshot(for: provider) else { continue }
                    fields += [snapshot.resourceID, snapshot.region, snapshot.accountID, snapshot.environment]
                    // Visibility controls presentation; all collected properties remain searchable.
                    fields += snapshot.fields.flatMap { [$0.title, $0.value] }
                }
                documents.append((host.id, fields.filter { !$0.isEmpty }))
            }
            guard !Task.isCancelled else { return [] }
            self.documents = documents; self.revision = revision
        }
        var result = Set<UUID>()
        for (id, fields) in documents {
            guard !Task.isCancelled else { return [] }
            if fields.contains(where: { TextSearch.contains($0, query: query) }) { result.insert(id) }
        }
        return result
    }
}
