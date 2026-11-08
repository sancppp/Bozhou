import Foundation
import BozhouCore
import BozhouExtensions

enum PluginTests {
    @MainActor static func run() async throws {
        let legacy = Data(#"{"metadataExtensions":{"fixture":{"enabled":true,"executable":"/usr/bin/true","environments":["test"],"layout":{"hidden":["field"],"order":["field"]}}}}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(migrated.plugins["fixture"]?.options["executable"], "/usr/bin/true")
        XCTAssertEqual(migrated.plugins["fixture"]?.selections["environments"], ["test"])
        XCTAssertEqual(migrated.plugins["fixture"]?.layout.hidden, ["field"])
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated)), migrated)

        let registry = PluginRegistry(), basic = FixturePlugin(id: "fixture.basic")
        try registry.register(basic)
        XCTAssertEqual(basic.events, ["register"])
        XCTAssertThrowsError(try registry.register(FixturePlugin(id: basic.descriptor.id)))
        XCTAssertTrue(registry.capabilities(FixtureCapability.self).isEmpty)
        var settings = PluginSettings(); settings.enabled = true
        settings.options["model"] = "fixture-model"
        registry.configure([basic.descriptor.id: settings])
        let first = try XCTUnwrap(basic.contexts.last)
        XCTAssertEqual(registry.capabilities(FixtureCapability.self).first?.label, "fixture.basic")
        XCTAssertTrue(registry.metadataProviders.isEmpty)
        XCTAssertEqual(first.settings.options["model"], "fixture-model")
        var taskStarted = false, taskStopped = false, publishedAfterStop = false
        first.run { context in
            taskStarted = true
            try? await Task.sleep(for: .seconds(30))
            publishedAfterStop = context.isActive
            taskStopped = true
        }
        try await wait { @MainActor in taskStarted }
        settings.layout.hidden = ["field"]
        registry.configure([basic.descriptor.id: settings])
        XCTAssertEqual(basic.contexts.count, 1)
        settings.options["model"] = "another-model"
        registry.configure([basic.descriptor.id: settings])
        XCTAssertTrue(!first.isActive)
        try await wait { @MainActor in taskStopped }
        XCTAssertTrue(!publishedAfterStop)
        XCTAssertEqual(basic.cleanups, 1)
        let second = try XCTUnwrap(basic.contexts.last)
        registry.stopWorkspace()
        XCTAssertTrue(!second.isActive)
        registry.configure([basic.descriptor.id: settings])
        let third = try XCTUnwrap(basic.contexts.last)
        XCTAssertTrue(third.workspaceID != second.workspaceID)
        registry.unregister(basic.descriptor.id)
        XCTAssertTrue(!third.isActive)
        XCTAssertEqual(basic.events, ["register", "activate", "deactivate", "activate", "deactivate", "activate", "deactivate", "unregister"])
        XCTAssertEqual(basic.cleanups, 3)
        XCTAssertTrue(registry.capabilities(FixtureCapability.self).isEmpty)
        try registry.register(basic) // Preserved settings can reactivate a newly registered plugin.
        XCTAssertTrue(registry.isActive(basic.descriptor.id))
        registry.configure([:])
        XCTAssertTrue(!registry.isActive(basic.descriptor.id))

        let failing = FixturePlugin(id: "fixture.failure", failsActivation: true)
        try registry.register(failing)
        registry.configure([failing.descriptor.id: settings])
        XCTAssertTrue(registry.failures[failing.descriptor.id] != nil)
        XCTAssertTrue(registry.capabilities(FixtureCapability.self).isEmpty)
        XCTAssertTrue(failing.contexts.last?.isActive == false)
        XCTAssertEqual(failing.cleanups, 1)

        let gate = PluginMetadataGate()
        let metadataPlugin = FixturePlugin(id: gate.id, metadata: gate)
        try registry.register(metadataPlugin)
        registry.configure([gate.id: settings])
        let host = Host(name: "fixture", address: "192.0.2.1")
        var received = 0
        registry.metadata.onSnapshot = { _, _ in received += 1 }
        registry.metadata.request(host)
        try await wait { await gate.count == 1 }
        registry.unregister(gate.id)
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received, 0)
        XCTAssertTrue(registry.metadata.statuses.isEmpty)
        try registry.register(metadataPlugin)
        registry.metadata.request(host)
        try await wait { await gate.count == 2 }
        registry.stopWorkspace()
        registry.metadata.request(host)
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        let stoppedCount = await gate.count
        XCTAssertEqual(stoppedCount, 2)
        XCTAssertEqual(received, 0)
        registry.configure([gate.id: settings])
        registry.metadata.request(host)
        try await wait { await gate.count == 3 }
        await gate.release(wrongSubject: true)
        try await wait { @MainActor in registry.metadata.status(hostID: host.id, providerID: gate.id)?.busy == false }
        XCTAssertEqual(received, 0)
        if case .failed = registry.metadata.status(hostID: host.id, providerID: gate.id) {} else { fail("Unmatched provider reply accepted") }
        registry.metadata.request(host, force: true)
        try await wait { await gate.count == 4 }
        await gate.release()
        try await wait { @MainActor in received == 1 }
        registry.shutdown()
        XCTAssertTrue(registry.descriptors.isEmpty)
        XCTAssertTrue(registry.metadata.statuses.isEmpty)
        let scoped = FixturePlugin(id: "fixture.scoped")
        var owner: PluginRegistry? = PluginRegistry()
        try owner?.register(scoped)
        owner?.configure([scoped.descriptor.id: settings])
        weak var released = owner
        owner = nil
        XCTAssertNil(released)
        try await wait { @MainActor in scoped.events.last == "unregister" }
        XCTAssertTrue(scoped.contexts.last?.isActive == false)
        print("PASS plugin framework: legacy settings, non-metadata capability, activation cleanup, configuration/workspace replacement, unregister/re-register, failure rollback, stale and mismatched replies")
    }
    private static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BozhouError.invalid("Plugin test timed out")
    }
}

private struct FixtureCapability: PluginCapability { let label: String }

@MainActor
private final class FixturePlugin: BozhouPlugin {
    let descriptor: PluginDescriptor
    let capabilities: [any PluginCapability]
    let failsActivation: Bool
    var events: [String] = []
    var contexts: [PluginContext] = []
    var cleanups = 0
    init(id: String, metadata: (any HostMetadataProvider)? = nil, failsActivation: Bool = false) {
        descriptor = PluginDescriptor(id: id, title: id)
        capabilities = metadata.map { [$0] } ?? [FixtureCapability(label: id)]
        self.failsActivation = failsActivation
    }
    func register() { events.append("register") }
    func activate(_ context: PluginContext) throws {
        contexts.append(context); events.append("activate")
        context.onStop { [weak self] in self?.cleanups += 1 }
        if failsActivation { throw BozhouError.invalid("Fixture activation failure") }
    }
    func deactivate() { events.append("deactivate") }
    func unregister() { events.append("unregister") }
}

private actor PluginMetadataGate: HostMetadataProvider {
    nonisolated var id: String { "fixture.metadata" }
    nonisolated var title: String { "Metadata fixture" }
    var count = 0
    var continuation: CheckedContinuation<Bool, Never>?
    func fetch(_ subject: MetadataSubject, settings: PluginSettings) async throws -> MetadataSnapshot {
        count += 1
        let wrongSubject = await withCheckedContinuation { continuation = $0 }
        return MetadataSnapshot(providerID: id, subjectKey: wrongSubject ? "wrong-host" : subject.key,
                                resourceID: "", region: "", accountID: "", environment: "",
                                fields: [.init(id: "vpc", title: "VPC", value: "fixture-vpc")], notices: [])
    }
    func release(wrongSubject: Bool = false) { continuation?.resume(returning: wrongSubject); continuation = nil }
}
