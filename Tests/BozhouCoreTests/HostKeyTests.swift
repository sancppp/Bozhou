import Foundation
import BozhouCore

extension CoreTests {
    func testHostKeysFollowConnectionRoute() throws {
        let paths = try AppPaths(root: root)
        let builder = ConnectionBuilder(paths: paths, askPass: "/usr/bin/false")
        func aliases(_ host: BozhouCore.Host, _ hosts: [BozhouCore.Host] = [], sftp: Bool = false) throws -> [String?] {
            let launch = try builder.build(host: host, hosts: hosts, identities: [], sftp: sftp)
            defer { launch.cleanup() }
            let config = try String(contentsOf: launch.directory.appendingPathComponent("config"), encoding: .utf8)
            return config.components(separatedBy: "\nHost bz-").dropFirst().map { block in
                block.components(separatedBy: "\n").first { $0.hasPrefix("    HostKeyAlias ") }
                    .map { String($0.dropFirst("    HostKeyAlias ".count)) }
            }
        }
        let gatewayA = Host(name: "A", address: "gateway-a.example", port: 2222)
        var gatewayB = gatewayA
        gatewayB.id = UUID(); gatewayB.address = "gateway-b.example"
        var relay = Host(name: "relay", address: "192.0.2.1")
        relay.jumpHosts = [gatewayA.id]
        var target = Host(name: "target", address: "192.0.2.2")
        target.jumpHosts = [relay.id]
        let routeA = try aliases(target, [gatewayA, relay])
        XCTAssertEqual(routeA.count, 3)
        XCTAssertNil(routeA[0])
        XCTAssertTrue(routeA[1] != nil && routeA[2] != nil && routeA[1] != routeA[2])
        relay.jumpHosts = [gatewayB.id]
        let routeB = try aliases(target, [gatewayB, relay])
        XCTAssertTrue(routeA[1] != routeB[1] && routeA[2] != routeB[2])

        // Reconnects, SFTP, metadata/credential edits and duplicate saved records all
        // retain trust for the same endpoint reached through the same route.
        XCTAssertEqual(try aliases(target, [gatewayB, relay], sftp: true), routeB)
        var duplicateGateway = gatewayB
        duplicateGateway.id = UUID(); duplicateGateway.name = "renamed"
        duplicateGateway.address = gatewayB.address.uppercased()
        duplicateGateway.username = "other"; duplicateGateway.authentication = .password
        duplicateGateway.password = "fixture-only"
        relay.id = UUID(); relay.jumpHosts = [duplicateGateway.id]
        target.id = UUID(); target.jumpHosts = [relay.id]; target.group = "moved"
        target.username = "other"; target.authentication = .password
        XCTAssertEqual(try aliases(target, [duplicateGateway, relay]), routeB)

        // Identity includes every endpoint and port, not just the immediate jump.
        duplicateGateway.port += 1
        let changedGateway = try aliases(target, [duplicateGateway, relay])
        XCTAssertTrue(changedGateway[1] != routeB[1] && changedGateway[2] != routeB[2])
        duplicateGateway.port -= 1
        relay.port += 1
        let changedRelay = try aliases(target, [duplicateGateway, relay])
        XCTAssertTrue(changedRelay[1] != routeB[1] && changedRelay[2] != routeB[2])
        relay.port -= 1
        target.port += 1
        let changedTarget = try aliases(target, [duplicateGateway, relay])
        XCTAssertEqual(changedTarget[1], routeB[1])
        XCTAssertTrue(changedTarget[2] != routeB[2])
        target.port -= 1
        target.address = "192.0.2.3"
        XCTAssertTrue(try aliases(target, [duplicateGateway, relay])[2] != routeB[2])

        // A hop keeps the same identity when connected as a destination itself.
        XCTAssertEqual(try aliases(relay, [duplicateGateway]), Array(routeB.prefix(2)))
        target.jumpHosts = []
        XCTAssertEqual(try aliases(target), [nil])
        XCTAssertEqual(try aliases(gatewayA), [nil])

        var proxy = ProxyConfiguration()
        proxy.host = "proxy.example"
        target.proxy = proxy
        let proxied = try aliases(target)
        XCTAssertTrue(proxied[0] != nil)
        XCTAssertEqual(try aliases(target, sftp: true), proxied)
        for changed in ["host", "port", "kind"] {
            var other = proxy
            switch changed {
            case "host": other.host = "other.example"
            case "port": other.port += 1
            default: other.kind = .http
            }
            target.proxy = other
            XCTAssertTrue(try aliases(target) != proxied)
        }
        duplicateGateway.proxy = proxy
        target.proxy = nil; target.jumpHosts = [relay.id]
        let proxyThenJumps = try aliases(target, [duplicateGateway, relay])
        XCTAssertTrue(proxyThenJumps.allSatisfy { $0 != nil })
        duplicateGateway.proxy?.port += 1
        let changedProxy = try aliases(target, [duplicateGateway, relay])
        XCTAssertTrue(zip(proxyThenJumps, changedProxy).allSatisfy { pair in pair.0 != pair.1 })

        // Building configurations must not rewrite or remove legacy fingerprints.
        let legacy = Data("legacy-known-hosts\n".utf8)
        try legacy.write(to: paths.knownHosts)
        _ = try aliases(target, [duplicateGateway, relay])
        XCTAssertEqual(try Data(contentsOf: paths.knownHosts), legacy)
    }
}
