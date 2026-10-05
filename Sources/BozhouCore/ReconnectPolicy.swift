import Foundation

public struct ReconnectPolicy {
    public static let delays = [5, 10, 30, 60, 120]
    public private(set) var attempts = 0
    public var exhausted: Bool { attempts >= Self.delays.count }
    public init() {}
    public mutating func reset() { attempts = 0 }
    public mutating func nextDelay(exitCode: Int?, output: String, enabled: Bool) -> Int? {
        guard enabled, exitCode == nil || exitCode == 255, !exhausted else { return nil }
        let message = output.lowercased()
        let permanent = ["permission denied", "host key verification failed", "remote host identification has changed",
                         "incorrect passphrase", "authentication failed", "too many authentication failures"]
        guard !permanent.contains(where: message.contains) else { return nil }
        let delay = Self.delays[attempts]
        attempts += 1
        return delay
    }
}
