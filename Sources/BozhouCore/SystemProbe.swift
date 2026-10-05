import Foundation

public enum SystemProbe {
    /// Bounded, read-only inventory in the authenticated connection, before shell recording starts.
    public static func script(token: String) -> String {
        """
        bz_info=$(
          {
            printf '[os]\\n'
            if [ -r /etc/os-release ]; then head -c 8192 /etc/os-release
            elif command -v sw_vers >/dev/null 2>&1; then sw_vers
            else uname -s; fi
            printf '\\n[hostname]\\n'; hostname 2>/dev/null || uname -n
            printf '\\n[kernel]\\n'; uname -srmo 2>/dev/null || uname -srm
            printf '\\n[cpu]\\n'
            if command -v lscpu >/dev/null 2>&1; then LC_ALL=C lscpu
            elif command -v sysctl >/dev/null 2>&1; then sysctl -n machdep.cpu.brand_string hw.ncpu
            fi
            printf '\\n[memory]\\n'
            if [ -r /proc/meminfo ]; then head -n 5 /proc/meminfo
            elif command -v sysctl >/dev/null 2>&1; then sysctl hw.memsize; fi
          } 2>/dev/null | head -c 24000 | base64 | tr -d '\\r\\n'
        )
        printf '\\033]777;bozhou;\(token);system;%s\\007' "$bz_info"
        unset bz_info
        """
    }
    public static func parse(_ encoded: String) -> SystemProfile? {
        guard encoded.count <= 40000, let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8), text.hasPrefix("[os]\n") else { return nil }
        var sections: [String: String] = [:], key = ""
        for line in text.components(separatedBy: "\n") {
            // Unknown sections must not be appended to the preceding field.
            if line.hasPrefix("["), line.hasSuffix("]") { key = line }
            else { sections[key, default: ""] += line + "\n" }
        }
        func field(_ key: String) -> String { sections[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) }
        let hostname = field("[hostname]").components(separatedBy: .newlines).first ?? ""
        return SystemProfile(operatingSystem: field("[os]"), kernel: field("[kernel]"), cpu: field("[cpu]"),
                             memory: field("[memory]"), hostname: hostname.isEmpty ? nil : hostname)
    }
}
