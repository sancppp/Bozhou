import Foundation

public struct SSHLaunch {
    public var executable = "/usr/bin/ssh"
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: URL
    public var token: String
    public var logURL: URL?
    public init(executable: String = "/usr/bin/ssh", arguments: [String], environment: [String: String], directory: URL, token: String, logURL: URL? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.directory = directory; self.token = token
        self.logURL = logURL
    }
    public func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

public struct ConnectionBuilder {
    public let paths: AppPaths
    public let askPass: String
    public init(paths: AppPaths, askPass: String) { self.paths = paths; self.askPass = askPass }

    public func validate(_ host: Host, hosts: [Host], identities: [Identity]) throws {
        guard !host.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw BozhouError.invalid("请输入主机名称") }
        guard validAddress(host.address) else { throw BozhouError.invalid("主机地址只能包含域名、IPv4 或 IPv6 地址") }
        guard (1...65535).contains(host.port) else { throw BozhouError.invalid("端口范围是 1～65535") }
        guard !host.username.isEmpty, host.username.range(of: #"^[a-zA-Z0-9_.@\\-]+$"#, options: .regularExpression) != nil,
              !host.username.hasPrefix("-") else { throw BozhouError.invalid("请输入有效的 SSH 用户名") }
        if host.authentication == .identity {
            guard let key = identities.first(where: { $0.id == host.identityID }) else { throw BozhouError.invalid("请先选择一个私钥") }
            guard key.privateKeyPath.hasPrefix("/"), safeConfigPath(key.privateKeyPath),
                  FileManager.default.isReadableFile(atPath: key.privateKeyPath) else { throw BozhouError.invalid("私钥文件不存在、路径无效或不可读取") }
        }
        if !host.shell.isEmpty {
            guard host.shell.hasPrefix("/"), host.shell.range(of: #"^/[a-zA-Z0-9_./-]+$"#, options: .regularExpression) != nil else {
                throw BozhouError.invalid("Shell 必须是绝对路径，例如 /bin/bash")
            }
        }
        for (name, value) in host.environment {
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  !value.contains("\0") else { throw BozhouError.invalid("环境变量名称或值无效：\(name)") }
        }
        if let proxy = host.proxy {
            guard validAddress(proxy.host), (1...65535).contains(proxy.port) else { throw BozhouError.invalid("代理地址或端口无效") }
            guard host.jumpHosts.isEmpty else { throw BozhouError.invalid("同一主机不能同时设置网络代理和跳板链") }
        }
        var ports: Set<Int> = []
        for forward in host.forwards where forward.enabled {
            guard (1...65535).contains(forward.localPort), (1...65535).contains(forward.remotePort),
                  validAddress(forward.remoteHost), ports.insert(forward.localPort).inserted else {
                throw BozhouError.invalid("转发端口须在 1～65535，同一主机的本地端口不能重复，目标地址须有效")
            }
        }
        _ = try chain(for: host, hosts: hosts)
    }

    public func chain(for host: Host, hosts: [Host]) throws -> [Host] {
        var result: [Host] = [], visited: Set<UUID> = [host.id]
        func visit(_ id: UUID) throws {
            guard visited.insert(id).inserted else { throw BozhouError.invalid("跳板链有循环或重复主机") }
            guard let hop = hosts.first(where: { $0.id == id }) else { throw BozhouError.invalid("跳板主机已被删除，请重新选择") }
            for next in hop.jumpHosts { try visit(next) }
            result.append(hop)
            guard result.count <= 12 else { throw BozhouError.invalid("跳板链最多支持 12 级") }
        }
        for id in host.jumpHosts { try visit(id) }
        return result
    }

    public func build(host: Host, hosts: [Host], identities: [Identity], sftp: Bool = false) throws -> SSHLaunch {
        try validate(host, hosts: hosts, identities: identities)
        let chain = try chain(for: host, hosts: hosts)
        for hop in chain { try validate(hop, hosts: hosts, identities: identities) }
        // A network proxy may precede the first hop only.
        guard !chain.dropFirst().contains(where: { $0.proxy != nil }) else {
            throw BozhouError.invalid("网络代理只能配置在跳板链的第一台主机上")
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = paths.sessions.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let configURL = directory.appendingPathComponent("config")
            var config = """
            Host *
                UserKnownHostsFile \(quoteConfig(paths.knownHosts.path))
                GlobalKnownHostsFile /dev/null
                StrictHostKeyChecking ask
                UpdateHostKeys no
                HashKnownHosts yes
                ConnectTimeout 15
                ServerAliveInterval 15
                ServerAliveCountMax 3
                TCPKeepAlive yes
                ForwardAgent no
                SendEnv LANG
                PermitLocalCommand no
                LogLevel VERBOSE
                NumberOfPasswordPrompts 3

            """
            for (index, item) in (chain + [host]).enumerated() {
                config += "\nHost bz-\(index)\n    HostName \(item.address)\n    User \(item.username)\n    Port \(item.port)\n"
                switch item.authentication {
                case .password:
                    config += "    PreferredAuthentications keyboard-interactive,password\n    PubkeyAuthentication no\n"
                case .identity:
                    let identity = identities.first { $0.id == item.identityID }!
                    config += "    IdentityFile \(quoteConfig(identity.privateKeyPath))\n    IdentitiesOnly yes\n    PreferredAuthentications publickey\n"
                case .agent:
                    // Disable ambient private-key files; agent identities remain available.
                    config += "    IdentityFile none\n    PreferredAuthentications publickey,keyboard-interactive,password\n"
                case .kerberos:
                    config += """
                        GSSAPIAuthentication yes
                        GSSAPIDelegateCredentials no
                        PreferredAuthentications gssapi-with-mic
                        PubkeyAuthentication no
                        PasswordAuthentication no
                        KbdInteractiveAuthentication no

                    """
                }
                if let proxy = item.proxy {
                    let kind = proxy.kind == .socks5 ? "5" : "connect"
                    let address = proxy.host.contains(":") ? "[\(proxy.host)]" : proxy.host
                    config += "    ProxyCommand /usr/bin/nc -X \(kind) -x \(address):\(proxy.port) %h %p\n"
                }
                if index > 0 {
                    // OpenSSH's implicit -J command does not quote its -F path. Build one
                    // shell-quoted command per hop; each child inherits its own credential ID.
                    let previous = chain[index - 1]
                    let args = ["/usr/bin/env", "BOZHOU_AUTH_HOST=\(previous.id.uuidString)",
                                "/usr/bin/ssh", "-F", configURL.path, "-W"]
                    let command = args.map { shellQuote($0).replacingOccurrences(of: "%", with: "%%") }.joined(separator: " ")
                    // OpenSSH invokes ProxyCommand through the user's shell with its own
                    // `exec` prefix. Adding another one breaks when that shell is Bash.
                    config += "    ProxyCommand \(command) '[%h]:%p' bz-\(index - 1)\n"
                }
            }
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = askPass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["BOZHOU_AUTH_HOST"] = host.id.uuidString
            env["BOZHOU_AUTH_DATABASE"] = paths.database.path
            env["BOZHOU_AUTH_SESSION"] = directory.path
            env["DISPLAY"] = "bozhou:0"
            env["TERM"] = "xterm-256color"
            env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
            let logURL = paths.logs.appendingPathComponent("\(token).ssh.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            var args = ["-E", logURL.path, "-F", configURL.path]
            if sftp {
                args += ["-T", "-s", "bz-\(chain.count)", "sftp"]
            } else {
                if host.forwards.contains(where: \.enabled) {
                    args += ["-o", "ExitOnForwardFailure=yes"]
                    for forward in host.forwards where forward.enabled { args += ["-L", forward.specification] }
                }
                args += ["-tt", "bz-\(chain.count)", ShellIntegration.bootstrap(host: host, token: token)]
            }
            return SSHLaunch(arguments: args, environment: env, directory: directory, token: token, logURL: logURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func validAddress(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") &&
        value.range(of: #"^[A-Za-z0-9_:][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil
    }
    private func safeConfigPath(_ value: String) -> Bool {
        !value.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\"" || $0 == "%" || $0 == "\\" })
    }
    private func quoteConfig(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%") + "\""
    }
}

public func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
