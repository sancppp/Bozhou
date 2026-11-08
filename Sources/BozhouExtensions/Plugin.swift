import Foundation
import BozhouCore

/// Capabilities are independent protocols; plugins need not supply metadata.
public protocol PluginCapability: Sendable {}

public struct PluginSetting: Identifiable, Sendable {
    public enum Kind: Sendable { case text, executable, choices([String]) }
    public let id: String
    public let title: String
    public let placeholder: String
    public let kind: Kind
    public init(_ id: String, title: String, placeholder: String = "", kind: Kind = .text) {
        self.id = id; self.title = title; self.placeholder = placeholder; self.kind = kind
    }
}

public struct PluginDescriptor: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let help: String
    public let settings: [PluginSetting]
    public let defaults: PluginSettings
    public init(id: String, title: String, summary: String = "", help: String = "",
                settings: [PluginSetting] = [], defaults: PluginSettings = PluginSettings()) {
        self.id = id; self.title = title; self.summary = summary; self.help = help
        self.settings = settings; self.defaults = defaults
    }
}

/// One activation per workspace/configuration. Invalidate before cancelling owned work.
@MainActor
public final class PluginContext {
    public let workspaceID: UUID
    public let settings: PluginSettings
    public private(set) var isActive = true
    private var cleanups: [() -> Void] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    init(workspaceID: UUID, settings: PluginSettings) {
        self.workspaceID = workspaceID; self.settings = settings
    }
    public func onStop(_ cleanup: @escaping () -> Void) {
        if isActive { cleanups.append(cleanup) } else { cleanup() }
    }
    /// Plugins must check isActive after awaits before publishing their own asynchronous results.
    public func run(_ operation: @escaping @MainActor (PluginContext) async -> Void) {
        guard isActive else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self, isActive, !Task.isCancelled else { return }
            defer { tasks[id] = nil }
            await operation(self)
        }
    }
    func stop() {
        isActive = false
        let running = tasks; tasks = [:]
        for task in running.values { task.cancel() }
        let pending = cleanups; cleanups = []
        for cleanup in pending.reversed() { cleanup() }
    }
}

/// Hooks run on the main actor and must return promptly; use context.run for background work.
@MainActor
public protocol BozhouPlugin: AnyObject {
    var descriptor: PluginDescriptor { get }
    var capabilities: [any PluginCapability] { get }
    func register() throws
    func activate(_ context: PluginContext) throws
    func deactivate()
    func unregister()
}

extension BozhouPlugin {
    public var capabilities: [any PluginCapability] { [] }
    public func register() throws {}
    public func activate(_ context: PluginContext) throws {}
    public func deactivate() {}
    public func unregister() {}
}
