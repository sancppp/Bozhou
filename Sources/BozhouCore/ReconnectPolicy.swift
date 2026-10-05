import Foundation

public struct ReconnectPolicy {
    public private(set) var attempts = 0
    public init() {}
    public mutating func reset() { attempts = 0 }
    public mutating func nextDelay(exitCode: Int?, output: String, enabled: Bool) -> Int? {
        guard enabled, exitCode == nil || exitCode == 255, attempts < 5 else { return nil }
        let message = output.lowercased()
        let permanent = ["permission denied", "host key verification failed", "remote host identification has changed",
                         "incorrect passphrase", "authentication failed", "too many authentication failures"]
        guard !permanent.contains(where: message.contains) else { return nil }
        let delay = [2, 4, 8, 16, 30][attempts]
        attempts += 1
        return delay
    }
}
