import Foundation
import BozhouCore
import BozhouExtensions
import BozhouNightHawk

private let providerID = NightHawkProvider.identifier

extension CoreTests {
    func testMetadataPersistence() throws {
        var host = Host(name: "iv-fixture00001", address: "192.0.2.8")
        let paths = try AppPaths(root: root.appendingPathComponent("metadata"))
        let store = try Store(url: paths.database)
        let other = try Store(url: paths.database)
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as! [String: Any]
        for key in ["metadataBindings", "metadataSnapshots", "metadataLayouts"] { oldJSON[key] = nil }
        let legacy = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertEqual(legacy.metadataSnapshots, [:])
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).plugins.isEmpty)
        try store.save(host)
        let draft = host
        let snapshot = MetadataSnapshot(providerID: providerID, subjectKey: MetadataSubject(host: host, providerID: providerID).key,
                                        resourceID: "i-fixture00001", region: "cn-test", accountID: "100", environment: "cn",
                                        fields: [.init(id: "future/value", title: "Future property", value: "new")], notices: [])
        try other.savePassword("changed-by-helper", hostID: host.id)
        XCTAssertTrue(try store.saveMetadata(snapshot, hostID: host.id))
        host = try XCTUnwrap(other.list(Host.self).first)
        XCTAssertEqual(host.password, "changed-by-helper")
        XCTAssertEqual(host.metadataSnapshot(for: providerID), snapshot)
        var edited = draft; edited.notes = "edited while fetching"; edited.password = host.password
        var layout = MetadataLayout()
        layout.hidden = ["future/value"]; layout.order = ["future/value"]
        edited.metadataLayouts[providerID] = layout
        try store.saveHostPreservingObservations(edited)
        host = try XCTUnwrap(other.list(Host.self).first)
        XCTAssertEqual(host.metadataSnapshot(for: providerID), snapshot)
        XCTAssertEqual(host.metadataLayouts[providerID], layout)
        XCTAssertEqual(host.notes, edited.notes)
        var settings = AppSettings(); var config = PluginSettings(); config.layout = layout
        settings.plugins[providerID] = config
        try store.saveSettings(settings)
        XCTAssertEqual(try other.loadSettings(), settings)
        let archive = root.appendingPathComponent("metadata.bozhoubackup")
        try WorkspaceBackup.capture(store: store, paths: paths).write(to: archive)
        let restored = try WorkspaceBackup.read(from: archive).restore(to: root.appendingPathComponent("metadata-restored"))
        XCTAssertEqual(try Store(url: restored.database).list(Host.self).first, host)
        XCTAssertEqual(try Store(url: restored.database).loadSettings(), settings)
        host.address = "192.0.2.9"; try other.save(host)
        XCTAssertTrue(try !store.saveMetadata(snapshot, hostID: host.id))
        XCTAssertNil(host.metadataSnapshot(for: providerID))
        try other.delete(Host.self, id: host.id)
        XCTAssertTrue(try !store.saveMetadata(snapshot, hostID: host.id))
        XCTAssertTrue(try store.list(Host.self).isEmpty)
        let fields = ["a", "b", "c"].map { MetadataField(id: $0, title: $0, value: $0) }
        layout = MetadataLayout(); layout.hidden = ["b"]; layout.move("c", by: -1, fields: fields)
        XCTAssertEqual(layout.arrange(fields, includeHidden: true).map(\.id), ["a", "c", "b"])
        XCTAssertEqual(layout.arrange(fields).map(\.id), ["a", "c"])
        XCTAssertEqual(layout.arrange(fields + [.init(id: "new", title: "new", value: "")]).map(\.id), ["a", "c", "new"])
    }
}

enum MetadataTests {
    static func run() async throws {
        var host = Host(name: "iv-fixture00001", address: "192.0.2.8")
        var settings = PluginSettings(); settings.enabled = true; settings.options["executable"] = "/usr/bin/true"
        let runner = MetadataFixture()
        let provider = NightHawkProvider(command: runner)
        let snapshot = try await provider.fetch(MetadataSubject(host: host, providerID: providerID), settings: settings)
        XCTAssertEqual(snapshot.accountID, "100")
        XCTAssertEqual(snapshot.region, "cn-test")
        XCTAssertTrue(snapshot.fields.contains { $0.id == "ECS/detail/实例信息/future/nested" && $0.value == "new" })
        XCTAssertTrue(snapshot.fields.contains { $0.id.contains("tag:purpose") && $0.value.contains("fixture") })
        XCTAssertTrue(snapshot.fields.contains { $0.id.hasSuffix("/unknown_column/value") })
        let calls = await runner.calls
        XCTAssertTrue(calls.contains { $0.contains("cn=2") })
        XCTAssertTrue(!calls.contains { $0.contains("/fixture/all-ecs") })
        XCTAssertTrue(calls.allSatisfy { $0.contains("--env") && $0.contains("--output") })
        XCTAssertTrue(snapshot.notices.contains { $0.contains("instance tags") })
        let crossAccount = try await NightHawkProvider(command: MetadataFixture(eniAccount: "200"))
            .fetch(MetadataSubject(host: host, providerID: providerID), settings: settings)
        XCTAssertEqual(crossAccount.accountID, "100")
        XCTAssertTrue(crossAccount.fields.contains { $0.id == "ENI/detail/基础信息/账户" && $0.value.contains("200") })
        let mismatchedRelated = try await NightHawkProvider(command: MetadataFixture(eniAccount: "200", relatedAccount: "300"))
            .fetch(MetadataSubject(host: host, providerID: providerID), settings: settings)
        XCTAssertTrue(mismatchedRelated.notices.contains { $0.contains("account does not match its attachment") })
        XCTAssertTrue(!mismatchedRelated.fields.contains { $0.id.hasPrefix("ENI/") })
        let rateLimited = MetadataFixture(rateLimitOnce: true)
        _ = try await NightHawkProvider(command: rateLimited).fetch(MetadataSubject(host: host, providerID: providerID), settings: settings)
        let retried = await rateLimited.calls
        XCTAssertEqual(retried.filter { $0[1] == "schema" && $0.contains("i-fixture00001") }.count, 2)
        print("PASS dynamic metadata: unknown nested fields, all columns, per-tag controls, pagination, scoped related resources")

        for mutation in 0..<4 {
            var bad = host
            if mutation == 0 { bad.address = "10.0.0.1" }
            if mutation == 1 { bad.name = "private-IP-only"; bad.address = "192.168.1.2" }
            if mutation == 2 { var binding = MetadataBinding(); binding.accountID = "200"; bad.metadataBindings[providerID] = binding }
            if mutation == 3 { bad.name += " i-other0000001" }
            do {
                _ = try await provider.fetch(MetadataSubject(host: bad, providerID: providerID), settings: settings)
                fail("Unsafe automatic metadata association accepted")
            } catch {}
        }
        // A manually verified ID supports DNS addresses; region/account remain checked.
        var binding = MetadataBinding(); binding.resourceID = "i-fixture00001"; binding.accountID = "100"; binding.region = "cn-test"
        host.address = "fixture.example"; host.metadataBindings[providerID] = binding
        _ = try await provider.fetch(MetadataSubject(host: host, providerID: providerID), settings: settings)
        settings.enabled = false
        let before = await runner.calls.count
        do { _ = try await provider.fetch(MetadataSubject(host: host, providerID: providerID), settings: settings); fail("Disabled provider ran") }
        catch is CancellationError {} catch { fail("Unexpected disabled error") }
        let after = await runner.calls.count
        XCTAssertEqual(before, after)
        print("PASS metadata identity: overlapping/private IP rejection, conflicting IDs, account/region constraints, explicit binding, disabled queries")

        let repeated = MetadataFixture(repeatPage: true)
        settings.enabled = true
        let partial = try await NightHawkProvider(command: repeated).fetch(MetadataSubject(host: host, providerID: providerID), settings: settings)
        XCTAssertTrue(partial.notices.contains { $0.contains("repeated a page") })
        try await testCommand()
        try await testCoordinator(host: host, snapshot: snapshot, settings: settings)
    }
    static func testCommand() async throws {
        let output = try await MetadataCommand().run(executable: "/usr/bin/printf", arguments: ["{\"ok\":true}"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "{\"ok\":true}")
        let start = Date()
        do { _ = try await MetadataCommand(timeout: 0.1).run(executable: "/bin/sleep", arguments: ["10"]); fail("Missing timeout") } catch {}
        XCTAssertTrue(Date().timeIntervalSince(start) < 2)
        do { _ = try await MetadataCommand(outputLimit: 64).run(executable: "/usr/bin/yes", arguments: []); fail("Missing output limit") } catch {}
        let pending = Task { try await MetadataCommand().run(executable: "/bin/sleep", arguments: ["10"]) }
        try await Task.sleep(for: .milliseconds(50)); pending.cancel()
        do { _ = try await pending.value; fail("Cancellation did not stop child") } catch is CancellationError {} catch { fail("Unexpected cancellation error") }
        do {
            _ = try await MetadataCommand().run(executable: "/bin/sh", arguments: [
                "-c", "printf '%s\\n' 'code=429 [log_id=fixture-request] token=do-not-echo' >&2; exit 1"
            ])
            fail("Missing structured rate-limit error")
        } catch MetadataFailure.rateLimited(let id) { XCTAssertEqual(id, "fixture-request") }
        catch { fail("Unexpected rate-limit error: \(error)") }
        let cooling = Task { try await MetadataCommand().run(executable: "/usr/bin/true", arguments: ["resource", "schema"]) }
        try await Task.sleep(for: .milliseconds(30)); cooling.cancel()
        do { _ = try await cooling.value; fail("Cooldown ignored cancellation") } catch is CancellationError {} catch { fail("Unexpected cooldown error") }
        print("PASS real CLI process: pipe draining, timeout, output bound and cancellation")
    }
    @MainActor static func testCoordinator(host: BozhouCore.Host, snapshot: MetadataSnapshot, settings: PluginSettings) async throws {
        let gate = MetadataGate(snapshot: snapshot)
        let coordinator = MetadataCoordinator(providers: [gate])
        var received = 0
        coordinator.onSnapshot = { _, _ in received += 1 }
        coordinator.request(host)
        try await Task.sleep(for: .milliseconds(20))
        let initialCount = await gate.count
        XCTAssertEqual(initialCount, 0)
        coordinator.configure([providerID: settings])
        coordinator.request(host); coordinator.request(host)
        try await wait { await gate.count == 1 }
        coordinator.configure([:])
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(received, 0)
        XCTAssertTrue(coordinator.statuses.isEmpty)
        coordinator.configure([providerID: settings])
        coordinator.request(host)
        try await wait { await gate.count == 2 }
        coordinator.cancel(hostID: host.id)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(received, 0)
        coordinator.request(host)
        try await wait { await gate.count == 3 }
        await gate.release()
        try await wait { @MainActor in received == 1 }
        let second = BozhouCore.Host(name: "second", address: "192.0.2.2")
        let third = BozhouCore.Host(name: "third", address: "192.0.2.3")
        coordinator.request(host, force: true)
        coordinator.request(second)
        coordinator.request(third)
        coordinator.request(third, priority: true)
        try await wait { await gate.count == 4 }
        await gate.release()
        try await wait { await gate.count == 5 }
        let nextID = await gate.subjectIDs.last
        XCTAssertEqual(nextID, third.id)
        await gate.release()
        try await wait { await gate.count == 6 }
        let lastID = await gate.subjectIDs.last
        XCTAssertEqual(lastID, second.id)
        coordinator.cancelAll() // Workspace replacement while a provider still has a late reply.
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(received, 3)
        XCTAssertTrue(coordinator.statuses.isEmpty)
        coordinator.cancelAll()
        print("PASS metadata queue: opt-in, deduplication, disable/delete late replies, successful delivery")
    }
    private static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BozhouError.invalid("Metadata test timed out")
    }
}

private actor MetadataGate: HostMetadataProvider {
    nonisolated var id: String { providerID }
    nonisolated var title: String { "Fixture" }
    var count = 0
    var subjectIDs: [UUID] = []
    let snapshot: MetadataSnapshot
    var continuation: CheckedContinuation<Void, Never>?
    init(snapshot: MetadataSnapshot) { self.snapshot = snapshot }
    func fetch(_ subject: MetadataSubject, settings: PluginSettings) async throws -> MetadataSnapshot {
        count += 1
        subjectIDs.append(subject.hostID)
        await withCheckedContinuation { continuation = $0 }
        // Intentionally ignores cancellation to exercise the lifecycle guard.
        var reply = snapshot; reply.subjectKey = subject.key
        return reply
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor MetadataFixture: MetadataCommandRunning {
    var calls: [[String]] = []
    let repeatPage: Bool
    let eniAccount: String
    let relatedAccount: String?
    let rateLimitOnce: Bool
    init(repeatPage: Bool = false, eniAccount: String = "100", relatedAccount: String? = nil, rateLimitOnce: Bool = false) {
        self.repeatPage = repeatPage; self.eniAccount = eniAccount; self.relatedAccount = relatedAccount; self.rateLimitOnce = rateLimitOnce
    }
    func run(executable: String, arguments: [String]) async throws -> Data {
        calls.append(arguments)
        if rateLimitOnce && calls.count == 1 { throw MetadataFailure.rateLimited("fixture-request") }
        func argument(_ flag: String) -> String { arguments[arguments.firstIndex(of: flag)! + 1] }
        let id = argument("--id")
        let isECS = id.hasPrefix("i-")
        func section(_ key: String, path: String) -> [String: Any] {
            ["key": key, "fields": [["key": "id", "label": "ID"]], "dataSource": [["type": "api", "url": path]]]
        }
        var data: [String: Any]
        if arguments[1] == "schema" {
            data = ["id": id, "type": isECS ? "i" : "eni", "region": "cn-test",
                    "detail": ["基础信息": ["账户": isECS ? "100" : relatedAccount ?? eniAccount], "实例信息": ["future": ["nested": "new"]]],
                    "list": isECS ? [
                        "网卡": section("eni_config", path: "/fixture/eni"),
                        "磁盘": section("volumes", path: "/fixture/volumes")
                    ] : [
                        "标签": section("tags", path: "/fixture/tags"),
                        "全部云服务器": section("ecs", path: "/fixture/all-ecs")
                    ]]
        } else {
            let path = argument("--path")
            let page = arguments.contains("cn=2") ? 2 : 1
            if path == "/fixture/eni" {
                data = ["tn": 1, "sn": 20, "items": [["network_interface_id": "eni-fixture00001",
                        "device_id": "i-fixture00001", "account_id": eniAccount, "primary_ip_address": "192.0.2.8",
                        "unknown_column": ["value": true]]]]
            } else if path == "/fixture/volumes" {
                data = ["tn": 2, "sn": 1, "items": [["id": repeatPage ? "vol1" : "vol\(page)", "size": page == 1 || repeatPage ? 20 : 40]]]
            } else if path == "/fixture/tags" {
                data = ["tn": 1, "sn": 20, "items": [["tag_key": "purpose", "tag_value": "fixture"]]]
            } else { throw BozhouError.invalid("Unscoped request") }
        }
        return try JSONSerialization.data(withJSONObject: ["code": 0, "success": true, "data": data])
    }
}
