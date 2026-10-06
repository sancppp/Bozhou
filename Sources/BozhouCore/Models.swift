import Foundation

public enum BozhouError: LocalizedError, Equatable {
    case invalid(String), storage(String), connection(String), protocolError(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .storage(let s), .connection(let s), .protocolError(let s): return s
        case .cancelled: return L10n.tr("Operation cancelled")
        }
    }
}

public protocol Record: Codable, Identifiable where ID == UUID {
    static var table: String { get }
}

public enum Authentication: String, Codable, CaseIterable, Identifiable {
    case agent, password, identity, kerberos
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .agent: return "SSH Agent"
        case .password: return L10n.tr("Password")
        case .identity: return L10n.tr("Private Key")
        case .kerberos: return "Kerberos"
        }
    }
}

public enum ProxyKind: String, Codable, CaseIterable, Identifiable {
    case socks5, http
    public var id: String { rawValue }
}

public struct ProxyConfiguration: Codable, Equatable {
    public var kind: ProxyKind = .socks5
    public var host = ""
    public var port = 1080
    public init() {}
}

public struct Host: Record, Equatable {
    public static let table = "hosts"
    public var id: UUID
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var password: String
    public var group: String
    public var tags: String
    public var authentication: Authentication
    public var identityID: UUID?
    public var jumpHosts: [UUID]
    public var shell: String
    public var environment: [String: String]
    public var proxy: ProxyConfiguration?
    public var color: String
    public var notes: String
    public var favorite: Bool
    public var createdAt: Date
    public var lastLoginAt: Date?
    public var systemProfile: SystemProfile?
    public var forwards: [LocalForward]
    public init(id: UUID = UUID(), name: String = "", address: String = "", port: Int = 22,
                username: String = "root", group: String = "", authentication: Authentication = .agent) {
        self.id = id; self.name = name; self.address = address; self.port = port
        self.username = username; self.group = group; self.authentication = authentication
        password = ""
        tags = ""; jumpHosts = []; shell = ""; environment = [:]; color = "blue"; notes = ""; favorite = false
        createdAt = Date(); forwards = []
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, password, group, tags, authentication, identityID, jumpHosts
        case shell, environment, proxy, color, notes, favorite, createdAt, lastLoginAt, systemProfile, forwards
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "root"
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        authentication = try c.decodeIfPresent(Authentication.self, forKey: .authentication) ?? .agent
        identityID = try c.decodeIfPresent(UUID.self, forKey: .identityID)
        jumpHosts = try c.decodeIfPresent([UUID].self, forKey: .jumpHosts) ?? []
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? ""
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        proxy = try c.decodeIfPresent(ProxyConfiguration.self, forKey: .proxy)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastLoginAt = try c.decodeIfPresent(Date.self, forKey: .lastLoginAt)
        systemProfile = try c.decodeIfPresent(SystemProfile.self, forKey: .systemProfile)
        forwards = try c.decodeIfPresent([LocalForward].self, forKey: .forwards) ?? []
    }
}

public struct HostFolder: Record, Equatable {
    public static let table = "folders"
    public var id = UUID()
    public var path: String
    public var createdAt = Date()
    public init(path: String) { self.path = path }
}

public struct LocalForward: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var enabled: Bool
    public init(localPort: Int = 58080, remoteHost: String = "127.0.0.1", remotePort: Int = 80, enabled: Bool = true) {
        self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort; self.enabled = enabled
    }
    public var specification: String {
        "127.0.0.1:\(localPort):\(remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost):\(remotePort)"
    }
}

public struct SystemProfile: Codable, Equatable {
    public var collectedAt = Date()
    public var hostname: String?
    public var operatingSystem: String
    public var kernel: String
    public var cpu: String
    public var memory: String
    public init(operatingSystem: String, kernel: String, cpu: String, memory: String, hostname: String? = nil) {
        self.hostname = hostname
        self.operatingSystem = operatingSystem; self.kernel = kernel; self.cpu = cpu; self.memory = memory
    }
}

public struct Identity: Record, Equatable {
    public static let table = "identities"
    public var id = UUID()
    public var name: String
    public var privateKeyPath: String
    public var publicKey: String
    public var fingerprint: String
    public init(name: String, privateKeyPath: String, publicKey: String = "", fingerprint: String = "") {
        self.name = name; self.privateKeyPath = privateKeyPath; self.publicKey = publicKey; self.fingerprint = fingerprint
    }
}

public struct Snippet: Record, Equatable {
    public static let table = "snippets"
    public var id = UUID()
    public var name: String
    public var command: String
    public var detail: String
    public init(name: String = "", command: String = "", detail: String = "") {
        self.name = name; self.command = command; self.detail = detail
    }
}

public struct Interaction: Record, Equatable {
    public static let table = "history"
    public var id = UUID()
    public var hostID: UUID?
    public var hostName: String
    public var hostname: String?
    public var sessionID: UUID
    public var date: Date
    public var shell: String
    public var command: String
    public var output: String
    public var exitCode: Int?
    public var truncated: Bool
    public init(hostID: UUID? = nil, hostName: String, sessionID: UUID, shell: String,
                command: String, output: String = "", exitCode: Int? = nil, date: Date = Date(), truncated: Bool = false,
                hostname: String? = nil) {
        self.hostID = hostID; self.hostName = hostName; self.sessionID = sessionID
        self.hostname = hostname
        self.shell = shell; self.command = command; self.output = output
        self.exitCode = exitCode; self.date = date; self.truncated = truncated
    }
}

public struct Pin: Record, Equatable {
    public static let table = "pins"
    public var id = UUID()
    public var title: String
    public var interaction: Interaction
    public init(_ interaction: Interaction, title: String? = nil) {
        self.interaction = interaction; self.title = title ?? interaction.command
    }
}

public struct AppSettings: Codable, Equatable {
    public var language: AppLanguage = .english
    public var fontName: String = "Menlo-Regular"
    public var fontSize: Double = 14
    public var appearance: String = "light"
    public var terminalBackgroundHex: String?
    public var autoReconnect: Bool = true
    public var saveHistory: Bool = true
    public var notifications: Bool = false
    public var historyLimit: Int = 1000
    public var expandedHostGroups: Set<String> = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, appearance, terminalBackgroundHex, autoReconnect, saveHistory, notifications, historyLimit
        case expandedHostGroups, language
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = AppLanguage(rawValue: try values.decodeIfPresent(String.self, forKey: .language) ?? "") ?? .english
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? "Menlo-Regular"
        fontSize = min(36, max(10, try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14))
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? "light"
        terminalBackgroundHex = try values.decodeIfPresent(String.self, forKey: .terminalBackgroundHex)
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        saveHistory = try values.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        historyLimit = min(3000, max(0, try values.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 1000))
        expandedHostGroups = try values.decodeIfPresent(Set<String>.self, forKey: .expandedHostGroups) ?? []
    }
}

public struct AppPaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("bozhou.sqlite") }
    public var knownHosts: URL { root.appendingPathComponent("known_hosts") }
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public init(root: URL) throws {
        self.root = root
        for path in [root, sessions, logs] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !FileManager.default.fileExists(atPath: knownHosts.path) {
            try Data().write(to: knownHosts)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
    }
}
