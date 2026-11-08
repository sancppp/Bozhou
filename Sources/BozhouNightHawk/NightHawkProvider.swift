import Foundation
import Darwin
import BozhouCore
import BozhouExtensions

public struct NightHawkProvider: HostMetadataProvider {
    public static let identifier = "volcengine.nighthawk"
    public var id: String { Self.identifier }
    public var title: String { "Volcengine · NightHawk" }
    public var presentation: MetadataPresentation { NightHawkPlugin.metadataPresentation }
    public func acceptsCache(_ snapshot: MetadataSnapshot, subject: MetadataSubject, settings: PluginSettings) -> Bool {
        let environments = subject.binding.environment.isEmpty
            ? (settings.selections["environments"] ?? NightHawkPlugin.defaultEnvironments) : [subject.binding.environment]
        return environments.contains(snapshot.environment)
    }
    private let command: any MetadataCommandRunning
    public init(command: any MetadataCommandRunning = MetadataCommand()) { self.command = command }
    public func fetch(_ subject: MetadataSubject, settings: PluginSettings) async throws -> MetadataSnapshot {
        guard settings.enabled else { throw CancellationError() }
        return try await NightHawkQuery(subject: subject, settings: settings, command: command).fetch()
    }
}

private final class NightHawkQuery {
    let subject: MetadataSubject
    let settings: PluginSettings
    let command: any MetadataCommandRunning
    let started = ProcessInfo.processInfo.systemUptime
    var requests = 0
    var executable = ""
    var environment = ""
    var fields = MetadataFields()
    var notices: [String] = []
    init(subject: MetadataSubject, settings: PluginSettings, command: any MetadataCommandRunning) {
        self.subject = subject; self.settings = settings; self.command = command
    }

    func fetch() async throws -> MetadataSnapshot {
        let manual = !subject.binding.resourceID.isEmpty
        let candidates = manual ? [subject.binding.resourceID] : Self.candidates(subject)
        guard candidates.count == 1, Self.validID(candidates[0], prefix: "i-") else {
            throw MetadataFailure.message(L10n.tr("Set an ECS instance ID in Host Details. An IP alone cannot identify an instance across accounts and VPCs."))
        }
        executable = try MetadataCommand.resolve(settings.options["executable"] ?? "")
        let environments = subject.binding.environment.isEmpty
            ? (settings.selections["environments"] ?? NightHawkPlugin.defaultEnvironments) : [subject.binding.environment]
        guard !environments.isEmpty, environments.allSatisfy({ NightHawkPlugin.environments.contains($0) }) else {
            throw MetadataFailure.message(L10n.tr("Select at least one valid NightHawk environment."))
        }
        var errors: [String] = []
        var seenEnvironments: Set<String> = []
        for env in environments where seenEnvironments.insert(env).inserted {
            try Task.checkCancellation()
            environment = env; fields = MetadataFields(); notices = []
            do {
                let schema = try await schema(candidates[0], region: subject.binding.region)
                let region = schema["region"] as? String ?? ""
                let account = Self.account(schema)
                guard !region.isEmpty, !account.isEmpty,
                      subject.binding.accountID.isEmpty || account == subject.binding.accountID else {
                    throw MetadataFailure.message(L10n.tr("The returned ECS account or region does not match the host binding."))
                }
                let sections = Self.sections(schema)
                guard let eni = sections.first(where: { $0.key == "eni_config" || $0.paths.contains(where: { $0.hasSuffix("/eni") }) }) else {
                    throw MetadataFailure.message(L10n.tr("The ECS schema did not provide network interfaces for identity verification."))
                }
                let interfaces = try await list(eni, id: candidates[0], region: region)
                guard interfaces.allSatisfy({
                    ($0["device_id"] as? String).map { $0 == candidates[0] } ?? false
                }), interfaces.allSatisfy({
                    ($0["account_id"] as? String).map { !$0.isEmpty } ?? false
                }) else {
                    throw MetadataFailure.message(L10n.tr("Network interface ownership does not match the ECS instance."))
                }
                if !manual {
                    let matches = interfaces.contains { row in
                        ["primary_ip_address", "ipv4_public_ip", "ipv6_address", "ipv6_public_ip", "secondary_ip_addresses"]
                            .contains { key in Self.containsAddress(row[key], address: subject.address) }
                    }
                    guard matches else {
                        throw MetadataFailure.message(L10n.tr("The inferred ECS instance does not match the connection address. Verify and set an explicit instance ID."))
                    }
                }
                addSchema(schema, source: "ECS", context: "")
                addList(interfaces, section: eni, source: "ECS", context: "")
                var related = Self.references(interfaces)
                if let detail = schema["detail"] as? [String: Any] {
                    for id in Self.resourceStrings(detail) where Self.validID(id, prefix: "vpc-") {
                        related[id, default: []].insert(account)
                    }
                }
                for section in sections where section.key != eni.key {
                    do {
                        let items = try await list(section, id: candidates[0], region: region)
                        addList(items, section: section, source: "ECS", context: "")
                    } catch is CancellationError { throw CancellationError() }
                    catch { notices.append(section.name + ": " + error.localizedDescription) }
                }
                let relatedIDs = related.keys.sorted {
                    let rank: (String) -> Int = { $0.hasPrefix("eni-") ? 0 : $0.hasPrefix("vpc-") ? 1 : $0.hasPrefix("subnet-") ? 2 : 3 }
                    return rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1)
                }
                if relatedIDs.count > 16 { notices.append(L10n.tr("Only the first 16 directly related resources were queried.")) }
                for resourceID in relatedIDs.prefix(16) {
                    do {
                        let relatedSchema = try await self.schema(resourceID, region: region)
                        let relatedAccount = Self.account(relatedSchema)
                        guard related[resourceID]?.contains(relatedAccount) == true else {
                            throw MetadataFailure.message(L10n.tr("The related resource account does not match its attachment; its details were omitted."))
                        }
                        let source = resourceID.hasPrefix("eni-") ? "ENI" : resourceID.hasPrefix("vpc-") ? "VPC"
                            : resourceID.hasPrefix("subnet-") ? "Subnet" : "EIP"
                        addSchema(relatedSchema, source: source, context: resourceID)
                        // Never expand VPC-wide ECS/ENI lists or recursively walk other tenants/resources.
                        for section in Self.sections(relatedSchema) where ["tags", "security_groups", "routetable", "network_acl", "quota"].contains(section.key) {
                            do {
                                let items = try await list(section, id: resourceID, region: region)
                                addList(items, section: section, source: source, context: resourceID)
                            } catch is CancellationError { throw CancellationError() }
                            catch { notices.append(source + " / " + section.name + ": " + error.localizedDescription) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { notices.append(resourceID + ": " + error.localizedDescription) }
                }
                if !sections.contains(where: { $0.key == "tags" }) && !Self.hasTags(schema["detail"]) {
                    notices.append(L10n.tr("This ECS schema does not expose instance tags. ENI, VPC and EIP tags are shown under their own resource names."))
                }
                if fields.limited { notices.append(L10n.tr("Some metadata exceeded the display limit and was truncated.")) }
                try Task.checkCancellation()
                return MetadataSnapshot(providerID: NightHawkProvider.identifier, subjectKey: subject.key,
                                        resourceID: candidates[0], region: region, accountID: account,
                                        environment: env, fields: fields.fields, notices: notices)
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append(env + ": " + error.localizedDescription) }
        }
        throw MetadataFailure.message(errors.joined(separator: "\n"))
    }

    private func request(_ arguments: [String]) async throws -> [String: Any] {
        func call() async throws -> Data {
            try Task.checkCancellation()
            guard requests < 96, ProcessInfo.processInfo.systemUptime - started < 180 else {
                throw MetadataFailure.message(L10n.tr("The metadata query limit was reached. Some related resources were omitted."))
            }
            requests += 1
            return try await command.run(executable: executable, arguments: arguments + ["--env", environment, "--output", "json"])
        }
        let bytes: Data
        do { bytes = try await call() }
        catch MetadataFailure.rateLimited { bytes = try await call() } // The real command runner enforces shared cooldown.
        try Task.checkCancellation()
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (response["code"] as? Int) == 0, response["success"] as? Bool != false,
              let data = response["data"] as? [String: Any] else {
            throw MetadataFailure.message(L10n.tr("NightHawk returned an unsuccessful response. Check local login, environment and resource permissions."))
        }
        return data
    }
    private func schema(_ id: String, region: String) async throws -> [String: Any] {
        var arguments = ["resource", "schema", "--id", id]
        if !region.isEmpty { arguments += ["--region", region] }
        let result = try await request(arguments)
        guard result["id"] as? String == id,
              region.isEmpty || result["region"] as? String == region else {
            throw MetadataFailure.message(L10n.tr("NightHawk returned a different resource ID or region."))
        }
        return result
    }
    private struct Section {
        let key: String
        let name: String
        let paths: [String]
        let labels: [String: String]
    }
    private static func sections(_ schema: [String: Any]) -> [Section] {
        guard let lists = schema["list"] as? [String: [String: Any]] else { return [] }
        return lists.keys.sorted().map { name in
            let section = lists[name]!
            let labels = (section["fields"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { result, field in
                if let key = field["key"] as? String { result[key] = field["label"] as? String ?? key }
            }
            let paths = (section["dataSource"] as? [[String: Any]] ?? []).compactMap { source -> String? in
                guard source["type"] as? String == "api", let path = source["url"] as? String,
                      path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"), !path.contains("#"),
                      !path.contains("..") else { return nil }
                return path
            }
            return Section(key: section["key"] as? String ?? name, name: name, paths: paths, labels: labels)
        }
    }
    private func list(_ section: Section, id: String, region: String) async throws -> [[String: Any]] {
        guard !section.paths.isEmpty else {
            throw MetadataFailure.message(L10n.tr("This metadata section has no supported query path."))
        }
        var items: [[String: Any]] = []
        for path in section.paths {
            var previous: Data?, received = 0
            for page in 1...10 {
                let response: [String: Any]
                do {
                    response = try await request(["resource", "get", "--id", id, "--region", region,
                                                  "--path", path, "--query", "cn=\(page)"])
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if items.isEmpty { throw error }
                    notices.append(section.name + ": " + error.localizedDescription); break
                }
                guard let rows = response["items"] as? [[String: Any]] else {
                    throw MetadataFailure.message(L10n.tr("NightHawk returned an unsupported list format."))
                }
                let pageData = try JSONSerialization.data(withJSONObject: rows, options: .sortedKeys)
                if previous == pageData, !rows.isEmpty {
                    notices.append(section.name + ": " + L10n.tr("Pagination repeated a page; remaining rows were omitted.")); break
                }
                previous = pageData
                let room = max(0, 500 - items.count)
                items.append(contentsOf: rows.prefix(room)); received += rows.count
                if rows.count > room { notices.append(section.name + ": " + L10n.tr("Only the first 500 rows were collected.")); break }
                if let total = response["tn"] as? Int, received >= total { break }
                let size = response["sn"] as? Int ?? 20
                if rows.isEmpty || (response["tn"] == nil && rows.count < size) { break }
                if page == 10 { notices.append(section.name + ": " + L10n.tr("Only the first 10 pages were collected.")) }
            }
        }
        return items
    }
    private func addSchema(_ schema: [String: Any], source: String, context: String) {
        // Preserve every returned detail field, including future nested attributes.
        for key in schema.keys.sorted() where key != "list" {
            fields.add(schema[key]!, path: [source, key], labels: key == "detail" ? [source] : [source, key], context: context)
        }
    }
    private func addList(_ rows: [[String: Any]], section: Section, source: String, context: String) {
        fields.list(rows, source: source, section: section.key, title: section.name, labels: section.labels, context: context)
    }
    private static func account(_ schema: [String: Any]) -> String {
        func search(_ object: Any?) -> String? {
            guard let object = object as? [String: Any] else { return nil }
            for key in ["账户", "账号", "account_id", "AccountId"] {
                if let value = object[key], !(value is NSNull) { return MetadataFields.text(value) }
            }
            for key in object.keys.sorted() { if let value = search(object[key]) { return value } }
            return nil
        }
        return search(schema["detail"]) ?? ""
    }
    private static func validID(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.count > prefix.count && value.count < 100
            && value.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    private static func candidates(_ subject: MetadataSubject) -> [String] {
        // iv-* is only a candidate: the returned ENI address must also match.
        let regex = try! NSRegularExpression(pattern: "(?<![a-zA-Z0-9-])i[v]?-[a-z0-9]{8,64}(?![a-zA-Z0-9-])")
        let values = [subject.hostname, subject.name].flatMap { value in
            regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match -> String? in
                guard let range = Range(match.range, in: value) else { return nil }
                let candidate = String(value[range])
                return candidate.hasPrefix("iv-") ? "i-" + candidate.dropFirst(3) : candidate
            }
        }
        return Array(Set(values)).sorted()
    }
    private static func references(_ interfaces: [[String: Any]]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for row in interfaces {
            guard let account = row["account_id"] as? String, !account.isEmpty else { continue }
            for key in ["network_interface_id", "vpc_id", "subnet_id", "ipv4_eip_id", "ipv6_eip_id"] {
                if let id = row[key] as? String, ["eni-", "vpc-", "subnet-", "eip-"].contains(where: { validID(id, prefix: $0) }) {
                    result[id, default: []].insert(account)
                }
            }
        }
        return result
    }
    private static func resourceStrings(_ value: Any) -> [String] {
        if let object = value as? [String: Any] { return object.values.flatMap(resourceStrings) }
        if let array = value as? [Any] { return array.flatMap(resourceStrings) }
        return (value as? String).map { [$0] } ?? []
    }
    private static func containsAddress(_ value: Any?, address: String) -> Bool {
        guard let value else { return false }
        if let array = value as? [Any] { return array.contains { containsAddress($0, address: address) } }
        if let object = value as? [String: Any] { return object.values.contains { containsAddress($0, address: address) } }
        guard let value = value as? String else { return false }
        for family in [AF_INET, AF_INET6] {
            var a = [UInt8](repeating: 0, count: 16), b = a
            if inet_pton(family, address, &a) == 1, inet_pton(family, value, &b) == 1, a == b { return true }
        }
        return false
    }
    private static func hasTags(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return object.contains { $0.key.lowercased().contains("tag") || $0.key.contains("标签") || hasTags($0.value) }
    }
}
