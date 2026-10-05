import Foundation
import BozhouCore

/// Explicitly invoked only with a user-authorized workspace and host name.
enum LiveProbe {
    static func run(workspace: String, name: String) async throws {
        let paths = try AppPaths(root: URL(fileURLWithPath: workspace))
        let store = try Store(url: paths.database)
        let hosts = try store.list(Host.self), identities = try store.list(Identity.self)
        let host = try XCTUnwrap(hosts.first { $0.name == name })
        let askpass = ProcessInfo.processInfo.environment["BOZHOU_PROBE_ASKPASS"] ??
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("BozhouAskPass").path
        let builder = ConnectionBuilder(paths: paths, askPass: askpass)
        let chain = try builder.chain(for: host, hosts: hosts)
        for attempt in 1...2 {
            let launch = try builder.build(host: host, hosts: hosts, identities: identities)
            defer { launch.cleanup() }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: launch.executable)
            process.arguments = ["-E", launch.logURL!.path, "-F", launch.directory.appendingPathComponent("config").path,
                                 "-T", "bz-\(chain.count)", "id -un; hostname; uname -s"]
            process.environment = launch.environment.merging(["BOZHOU_ASKPASS_NONINTERACTIVE": "1"]) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = output
            try process.run()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            print("\(name) connection \(attempt): exit=\(process.terminationStatus)")
            print(String(decoding: response, as: UTF8.self))
            guard process.terminationStatus == 0 else { throw BozhouError.connection("Read-only probe failed: \(launch.logURL!.path)") }
            let log = try String(contentsOf: launch.logURL!)
            for line in log.components(separatedBy: .newlines) where line.contains("Authenticated to") { print(line) }
        }
        var launch = try builder.build(host: host, hosts: hosts, identities: identities, sftp: true)
        launch.environment["BOZHOU_ASKPASS_NONINTERACTIVE"] = "1"
        let client = SFTPClient(launch: launch)
        defer { client.cancel() }
        let home = try await client.connect()
        let items = try await client.list(home)
        print("\(name) readonly SFTP: \(items.count) entries; no writes")
    }
}
