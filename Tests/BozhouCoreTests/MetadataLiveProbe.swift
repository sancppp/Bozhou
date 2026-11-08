import Foundation
import BozhouCore
import BozhouExtensions
import BozhouNightHawk

/// Explicit opt-in, read-only cloud queries. Input contains only metadata selectors, never a workspace database.
enum MetadataLiveProbe {
    private struct Target: Decodable {
        var name: String
        var address: String
        var hostname: String
        var resourceID: String?
        var region: String?
        var accountID: String?
        var environment: String?
    }
    static func run(input: URL, output: URL) async throws {
        let targets = try JSONDecoder().decode([Target].self, from: Data(contentsOf: input))
        guard (1...10).contains(targets.count), !FileManager.default.fileExists(atPath: output.path) else {
            throw BozhouError.invalid("Use 1–10 targets and a new output directory")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var settings = PluginSettings(); settings.enabled = true
        let provider = NightHawkProvider()
        var accounts: Set<String> = [], regions: Set<String> = []
        for (index, target) in targets.enumerated() {
            var host = BozhouCore.Host(name: target.name, address: target.address)
            host.systemProfile = SystemProfile(operatingSystem: "", kernel: "", cpu: "", memory: "", hostname: target.hostname)
            var binding = MetadataBinding()
            binding.resourceID = target.resourceID ?? ""; binding.region = target.region ?? ""
            binding.accountID = target.accountID ?? ""; binding.environment = target.environment ?? ""
            host.metadataBindings[provider.id] = binding
            let snapshot = try await provider.fetch(MetadataSubject(host: host, providerID: provider.id), settings: settings)
            let url = output.appendingPathComponent("snapshot-\(index + 1).json")
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            accounts.insert(snapshot.accountID); regions.insert(snapshot.region)
            print("PASS live ECS \(index + 1): \(snapshot.fields.count) fields, \(snapshot.notices.count) notices")
        }
        print("PASS live metadata: \(targets.count) ECS, \(accounts.count) accounts, \(regions.count) regions; no workspace writes")
    }
}
