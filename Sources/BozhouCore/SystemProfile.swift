import Foundation

/// Compact observations, also normalizing command output saved by older versions.
public struct SystemProfile: Codable, Equatable, Sendable {
    public var collectedAt = Date()
    public var hostname: String?
    public var operatingSystem: String
    public var kernel: String
    public var cpu: String
    public var cpuLogicalCount: Int?
    /// Available memory in GiB at collection time, not installed capacity.
    public var memory: String
    public var cpuSummary: String {
        guard let count = cpuLogicalCount else { return cpu }
        return [cpu, L10n.tr("\(count) logical CPUs")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public init(operatingSystem: String, kernel: String, cpu: String, memory: String, hostname: String? = nil) {
        self.hostname = hostname
        self.operatingSystem = Self.osName(operatingSystem)
        self.kernel = kernel
        let parsedCPU = Self.parseCPU(cpu)
        self.cpu = parsedCPU.0
        cpuLogicalCount = parsedCPU.1
        self.memory = Self.availableMemory(memory)
    }

    private enum CodingKeys: String, CodingKey {
        case collectedAt, hostname, operatingSystem, kernel, cpu, cpuLogicalCount, memory
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(operatingSystem: try c.decode(String.self, forKey: .operatingSystem),
                  kernel: try c.decode(String.self, forKey: .kernel),
                  cpu: try c.decode(String.self, forKey: .cpu),
                  memory: try c.decode(String.self, forKey: .memory),
                  hostname: try c.decodeIfPresent(String.self, forKey: .hostname))
        collectedAt = try c.decode(Date.self, forKey: .collectedAt)
        cpuLogicalCount = try c.decodeIfPresent(Int.self, forKey: .cpuLogicalCount) ?? cpuLogicalCount
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private static func properties(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(text) {
            guard let index = line.firstIndex(of: separator) else { continue }
            result[String(line[..<index]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
              value.last == quote else { return value }
        let body = String(value.dropFirst().dropLast())
        guard quote == "\"" else { return body }
        // os-release uses shell quoting, but must never be evaluated as shell code.
        var result = "", escaped = false
        for character in body {
            if escaped {
                if !"\"\\$`".contains(character) { result.append("\\") }
                result.append(character); escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
    private static func osName(_ text: String) -> String {
        let release = properties(text, separator: "=")
        if let pretty = release["PRETTY_NAME"], !unquote(pretty).isEmpty { return unquote(pretty) }
        if let name = release["NAME"] {
            return [unquote(name), release["VERSION"].map(unquote) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let mac = properties(text, separator: ":")
        if let name = mac["ProductName"] {
            return [name, mac["ProductVersion"] ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return lines(text).first(where: { !$0.contains("=") && !$0.contains(":") }) ?? ""
    }
    private static func parseCPU(_ text: String) -> (String, Int?) {
        let values = properties(text, separator: ":")
        let count = values["CPU(s)"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        if !values.isEmpty { return (values["Model name"] ?? values["Architecture"] ?? "", count) }
        let rows = lines(text)
        // sysctl -n prints the CPU brand and logical processor count on separate lines.
        let macCount = rows.count == 2 ? Int(rows[1]).flatMap { $0 > 0 ? $0 : nil } : nil
        return (rows.first ?? "", macCount)
    }
    private static func availableMemory(_ text: String) -> String {
        let values = properties(text, separator: ":")
        func number(_ value: String?) -> Double? {
            guard let value, let word = value.split(whereSeparator: { $0.isWhitespace }).first,
                  let value = Double(word.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                  value.isFinite, value >= 0 else { return nil }
            return value
        }
        var bytes: Double?
        if let available = number(values["MemAvailable"]) { bytes = available * 1024 }
        else if let header = lines(text).first(where: { $0.contains("page size of") }),
                let sizeText = header.components(separatedBy: "page size of ").last,
                let pageSize = number(sizeText), pageSize > 0,
                let free = number(values["Pages free"]), let inactive = number(values["Pages inactive"]) {
            // Reclaimable pages; purgeable pages overlap inactive/active and must not be added again.
            bytes = (free + inactive + (number(values["Pages speculative"]) ?? 0)) * pageSize
        }
        if let bytes, bytes.isFinite {
            return String(format: "%.2f GiB", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_073_741_824)
        }
        // Keep older already summarized values. A raw MemTotal/hw.memsize is not available memory.
        let rows = lines(text)
        return rows.count == 1 && values.isEmpty ? rows[0] : ""
    }
}
