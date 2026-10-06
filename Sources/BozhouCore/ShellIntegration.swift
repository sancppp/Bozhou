import Foundation

public enum ShellIntegration {
    private static let bashPreexec: String = {
        // Resolve packaged resources before touching Bundle.module (its fallback may be a build path).
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Bozhou_BozhouCore.bundle")
        let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = bundle.url(forResource: "bash-preexec", withExtension: "sh"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bash-preexec resource")
        }
        return script
    }()

    // Shell builtins only: no base64/tr processes per command. Escape protocol separators first.
    private static func hooks(token: String, shell: String, zsh: Bool = false) -> String {
        """
        __bz_preexec() {
          \(zsh ? "builtin emulate -L zsh" : "")
          builtin local __bz_command="$1"
          __bz_command="${__bz_command//\\%/%25}"
          __bz_command="${__bz_command//;/%3B}"
          __bz_command="${__bz_command//$'\\e'/%1B}"
          __bz_command="${__bz_command//$'\\a'/%07}"
          __bz_command="${__bz_command//$'\\n'/%0A}"
          __bz_command="${__bz_command//$'\\r'/%0D}"
          builtin printf '\\033]777;bozhou;\(token);command;%s;%s\\007' "\(shell)" "$__bz_command"
          return 0
        }
        __bz_precmd() {
          builtin local __bz_code=$?
          \(zsh ? "builtin emulate -L zsh" : "")
          builtin printf '\\033]777;bozhou;\(token);end;%s\\007' "$__bz_code"
          return \(zsh ? "0" : "\"$__bz_code\"")
        }
        """
    }

    /// Only ephemeral zsh startup files are created, on the remote host. They remove themselves.
    public static func bootstrap(host: Host, token: String, local: Bool = false) -> String {
        let environment = host.environment.sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuote($0.value));" }.joined(separator: " ")
        let shell = host.shell.isEmpty ? "\"${SHELL:-/bin/sh}\"" : shellQuote(host.shell)
        let script = """
        \(environment)
        \(local ? "export BOZHOU_LOCAL=1" : SystemProbe.script(token: token))
        bz_shell=\(shell)
        export BOZHOU_SHELL="$bz_shell"
        case "$bz_shell" in
          */bash)
            "$bz_shell" --rcfile /dev/fd/3 -i 3<<'BOZHOU_\(token)'
        \(bash(token: token))
        BOZHOU_\(token)
            ;;
          */zsh)
            bz_dir=$(mktemp -d "${TMPDIR:-/tmp}/bozhou.XXXXXXXX") || exit 1
            trap 'rm -f -- "$bz_dir/.zshrc" "$bz_dir/.zshenv"; rmdir -- "$bz_dir" 2>/dev/null' 0
            export BOZHOU_OLD_ZDOTDIR="${ZDOTDIR:-$HOME}"
            export BOZHOU_BOOTDIR="$bz_dir"
            cat >"$bz_dir/.zshenv" <<'BOZHOU_ENV'
        ZDOTDIR="$BOZHOU_OLD_ZDOTDIR"
        [[ -r "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
        BOZHOU_OLD_ZDOTDIR="${ZDOTDIR:-$HOME}"
        ZDOTDIR="$BOZHOU_BOOTDIR"
        BOZHOU_ENV
            cat >"$bz_dir/.zshrc" <<'BOZHOU_\(token)'
        \(zsh(token: token))
        BOZHOU_\(token)
            ZDOTDIR="$bz_dir" "$bz_shell" -i
            ;;
          *) printf '\\033]777;bozhou;\(token);ready;other\\007'; "$bz_shell" -i ;;
        esac
        bz_code=$?
        printf '\\033]777;bozhou;\(token);exit;%s\\007' "$bz_code"
        exit "$bz_code"
        """
        return "exec /bin/sh -c " + shellQuote(script)
    }

    public static func bash(token: String) -> String {
        """
        [[ -r ~/.bashrc ]] && source ~/.bashrc
        __bz_load_preexec() {
        \(bashPreexec)
        }
        __bz_load_preexec
        unset -f __bz_load_preexec
        \(hooks(token: token, shell: "${BOZHOU_SHELL:-$BASH}"))
        preexec_functions=(__bz_preexec "${preexec_functions[@]}")
        precmd_functions=(__bz_precmd "${precmd_functions[@]}")
        printf '\\033]777;bozhou;\(token);ready;bash\\007'
        """
    }

    public static func zsh(token: String) -> String {
        """
        __bz_bootdir="$ZDOTDIR"
        ZDOTDIR="$BOZHOU_OLD_ZDOTDIR"
        unset BOZHOU_OLD_ZDOTDIR BOZHOU_BOOTDIR
        [[ -r "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
        if [[ "${BOZHOU_LOCAL:-}" == 1 ]] && (( ! $+functions[omz] )); then
          export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
          if [[ -r "$ZSH/oh-my-zsh.sh" ]]; then
            zstyle ':omz:update' mode disabled
            source "$ZSH/oh-my-zsh.sh"
          fi
        fi
        unset BOZHOU_LOCAL
        rm -f -- "$__bz_bootdir/.zshrc" "$__bz_bootdir/.zshenv"
        rmdir -- "$__bz_bootdir" 2>/dev/null
        unset __bz_bootdir
        () {
        builtin emulate -L zsh
        \(hooks(token: token, shell: "${BOZHOU_SHELL:-/bin/zsh}", zsh: true))
        # Zsh passes the original status to each native precmd hook. Do not copy or
        # replace the user's precmd: themes may redefine it when reloaded.
        # Return success so a failed command cannot suppress later prompt hooks.
        preexec_functions=(__bz_preexec ${preexec_functions:#__bz_preexec})
        precmd_functions=(__bz_precmd ${precmd_functions:#__bz_precmd})
        }
        printf '\\033]777;bozhou;\(token);ready;zsh\\007'
        """
    }
}

/// Streaming byte parser: UTF-8 and OSC boundaries may be split across arbitrary PTY reads.
public final class InteractionRecorder {
    public var onInteraction: ((Interaction) -> Void)?
    public var onReady: ((String) -> Void)?
    public var onSystemProfile: ((SystemProfile) -> Void)?
    public let maximumOutput: Int
    private let prefix: [UInt8]
    private var pending: [UInt8] = []
    private var output: [UInt8] = []
    private var active: Interaction?
    private let hostID: UUID?
    private let hostName: String
    private var hostname: String?
    private let sessionID: UUID
    private var outputTail: OutputTail
    public private(set) var shellExitCode: Int?
    public var recentOutput: [UInt8] { outputTail.bytes }
    public init(token: String, hostID: UUID?, hostName: String, sessionID: UUID, maximumOutput: Int = 256 * 1024,
                hostname: String? = nil) {
        prefix = Array("\u{1b}]777;bozhou;\(token);".utf8)
        self.hostID = hostID; self.hostName = hostName; self.sessionID = sessionID; self.maximumOutput = max(0, maximumOutput)
        outputTail = OutputTail(limit: self.maximumOutput)
        self.hostname = hostname
    }

    /// Returns terminal display bytes with our private markers removed.
    public func feed(_ data: [UInt8]) -> [UInt8] {
        feed(data[...])
    }

    public func feed(_ data: ArraySlice<UInt8>) -> [UInt8] {
        pending += data
        var visible: [UInt8] = [], cursor = 0, plain = 0
        while cursor < pending.count {
            if pending[cursor] == prefix[0] {
                let available = min(prefix.count, pending.count - cursor)
                if pending[cursor..<(cursor + available)].elementsEqual(prefix.prefix(available)) {
                    if available < prefix.count { break }
                    guard let end = pending[(cursor + prefix.count)...].firstIndex(of: 7) else {
                        if pending.count - cursor > 65536 { cursor += 1; continue }
                        break
                    }
                    let before = pending[plain..<cursor]
                    appendOutput(before); visible += before
                    let fields = String(decoding: pending[(cursor + prefix.count)..<end], as: UTF8.self).components(separatedBy: ";")
                    marker(fields)
                    cursor = end + 1; plain = cursor; continue
                }
            }
            cursor += 1
        }
        let before = pending[plain..<cursor]
        appendOutput(before); visible += before
        pending.removeFirst(cursor)
        outputTail.append(visible[...])
        return visible
    }

    public func finish(exitCode: Int? = nil) {
        outputTail.append(pending[...])
        appendOutput(pending[...]); pending.removeAll()
        if var current = active {
            current.output = Self.clean(String(decoding: output, as: UTF8.self))
            current.exitCode = exitCode
            onInteraction?(current)
        }
        active = nil; output.removeAll()
    }

    private func appendOutput(_ bytes: ArraySlice<UInt8>) {
        guard active != nil else { return }
        let remaining = max(0, maximumOutput - output.count)
        output += bytes.prefix(remaining)
        if bytes.count > remaining { active?.truncated = true }
    }
    private func marker(_ fields: [String]) {
        guard let kind = fields.first else { return }
        if kind == "system", fields.count == 2, let profile = SystemProbe.parse(fields[1]) {
            hostname = profile.hostname ?? hostname
            onSystemProfile?(profile)
        }
        if kind == "exit", fields.count == 2, let code = Int(fields[1]), (0...255).contains(code) {
            shellExitCode = code
        }
        if kind == "ready", fields.count >= 2 { onReady?(fields[1]) }
        if kind == "command", fields.count >= 3, let command = fields[2].removingPercentEncoding {
            if var current = active {
                current.output = Self.clean(String(decoding: output, as: UTF8.self))
                onInteraction?(current)
            }
            active = Interaction(hostID: hostID, hostName: hostName, sessionID: sessionID,
                                 shell: fields[1].hasPrefix("/") ? "#!\(fields[1])" : "#!/bin/\(fields[1])",
                                 command: command, hostname: hostname)
            output.removeAll()
        }
        if kind == "end", var current = active {
            current.output = Self.clean(String(decoding: output, as: UTF8.self))
            current.exitCode = fields.count > 1 ? Int(fields[1]) : nil
            active = nil; output.removeAll()
            onInteraction?(current)
        }
    }
    public static func clean(_ string: String) -> String {
        string.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
    }
}

/// Lazily filled circular storage. Small PTY reads overwrite only the oldest
/// bytes instead of shifting the entire (up to 256 KiB) tail on every read.
private struct OutputTail {
    let limit: Int
    private var storage: [UInt8] = []
    private var start = 0

    init(limit: Int) { self.limit = limit }

    var bytes: [UInt8] {
        guard start > 0 else { return storage }
        var result: [UInt8] = []
        result.reserveCapacity(storage.count)
        result += storage[start...]
        result += storage[..<start]
        return result
    }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        guard limit > 0, !bytes.isEmpty else { return }
        if bytes.count >= limit {
            storage = Array(bytes.suffix(limit))
            start = 0
            return
        }
        let growth = min(limit - storage.count, bytes.count)
        storage += bytes.prefix(growth)
        let remainder = bytes.dropFirst(growth)
        guard !remainder.isEmpty else { return }
        let first = min(remainder.count, limit - start)
        storage.replaceSubrange(start..<(start + first), with: remainder.prefix(first))
        if first < remainder.count {
            storage.replaceSubrange(0..<(remainder.count - first), with: remainder.dropFirst(first))
        }
        start = (start + remainder.count) % limit
    }
}
