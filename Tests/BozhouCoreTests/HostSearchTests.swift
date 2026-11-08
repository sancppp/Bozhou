import Foundation
import BozhouCore

enum HostSearchTests {
    static func run() async {
        let provider = "test.metadata"
        let jump = Host(name: "jump-café", address: "192.0.2.1")
        var host = Host(name: "worker", address: "192.0.2.2", port: 2222, group: "production/payments")
        host.password = "password-marker"; host.environment["TOKEN"] = "secret-env-marker"
        host.notes = "owner-platform"
        host.jumpHosts = [jump.id]
        host.systemProfile = SystemProfile(operatingSystem: "PRETTY_NAME=\"Debian 12\"", kernel: "6.1", cpu: "Model name: EPYC\nCPU(s): 16",
                                           memory: "MemAvailable: 8388608 kB", hostname: "compute-123456")
        host.metadataSnapshots[provider] = MetadataSnapshot(
            providerID: provider, subjectKey: MetadataSubject(host: host, providerID: provider).key,
            resourceID: "i-fixture", region: "test-region", accountID: "test-account", environment: "test",
            fields: [.init(id: "VPC/id", title: "VPC › identifier", value: "vpc-shared-example"),
                     .init(id: "ENI/id", title: "ENI › identifier", value: "eni-unique-example")], notices: [])
        let index = HostSearchIndex()
        for query in ["debian", "16 logical", "8.00 GiB", "owner-platform", "production", "2222", "compute-123456",
                      "vpc-SHARED", "eni-unique", "test-region", "test-account"] {
            let matches = await index.matches(hosts: [jump, host], enabledProviders: [provider], revision: 1, query: query)
            XCTAssertEqual(matches, [host.id])
        }
        let jumpMatches = await index.matches(hosts: [jump, host], enabledProviders: [provider], revision: 1, query: "jump-cafe")
        XCTAssertEqual(jumpMatches, [jump.id, host.id])
        for query in ["password-marker", "secret-env-marker"] {
            let matches = await index.matches(hosts: [jump, host], enabledProviders: [provider], revision: 1, query: query)
            XCTAssertTrue(matches.isEmpty)
        }
        let disabled = await index.matches(hosts: [jump, host], enabledProviders: [], revision: 2, query: "vpc-shared")
        XCTAssertTrue(disabled.isEmpty)
        var mismatched = host
        mismatched.metadataSnapshots[provider]?.providerID = "another.provider"
        XCTAssertNil(mismatched.metadataSnapshot(for: provider))
        host.address = "192.0.2.3"
        let outdated = await index.matches(hosts: [jump, host], enabledProviders: [provider], revision: 3, query: "vpc-shared")
        XCTAssertTrue(outdated.isEmpty)
        print("PASS host detail search: system summaries, jump names, Unicode, enabled metadata, stale cache and credential exclusions")
    }
}
