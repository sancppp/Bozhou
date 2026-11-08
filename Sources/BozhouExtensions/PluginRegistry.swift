import Foundation
import Combine
import BozhouCore

/// Composition and lifecycle only. No vendor imports, CLI paths, database or credentials.
@MainActor
public final class PluginRegistry: ObservableObject {
    @Published public private(set) var descriptors: [PluginDescriptor] = []
    @Published public private(set) var failures: [String: String] = [:]
    public let metadata = MetadataCoordinator()
    public var onChange: (() -> Void)?
    private var plugins: [String: any BozhouPlugin] = [:]
    private var registeredCapabilities: [String: [any PluginCapability]] = [:]
    private var contexts: [String: PluginContext] = [:]
    private var settings: [String: PluginSettings] = [:]
    private var workspaceID = UUID()
    public init() {}
    deinit {
        // Release scoped work even when a host drops the registry without explicit shutdown.
        let active = contexts, registered = plugins
        Task { @MainActor in
            for context in active.values { context.stop() }
            for (id, plugin) in registered {
                if active[id] != nil { plugin.deactivate() }
                plugin.unregister()
            }
        }
    }

    public func register(_ plugin: any BozhouPlugin) throws {
        let descriptor = plugin.descriptor
        guard !descriptor.id.isEmpty, descriptor.id.count <= 128,
              descriptor.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              plugins[descriptor.id] == nil else {
            throw BozhouError.invalid(L10n.tr("The plugin ID is empty or already registered."))
        }
        let capabilities = plugin.capabilities
        let providers = capabilities.compactMap { $0 as? any HostMetadataProvider }
        guard providers.count <= 1, providers.allSatisfy({ $0.id == descriptor.id }) else {
            throw BozhouError.invalid(L10n.tr("A plugin's metadata provider must use its plugin ID."))
        }
        do { try plugin.register() }
        catch { plugin.unregister(); throw error }
        plugins[descriptor.id] = plugin
        registeredCapabilities[descriptor.id] = capabilities
        descriptors.append(descriptor)
        for provider in providers { metadata.register(provider) }
        reconcile(descriptor.id)
        updateMetadata()
    }

    public func unregister(_ id: String) {
        guard let plugin = plugins[id] else { return }
        stop(id)
        metadata.unregister(id)
        plugin.unregister()
        plugins[id] = nil; registeredCapabilities[id] = nil
        descriptors.removeAll { $0.id == id }; failures[id] = nil
        updateMetadata()
    }

    public func configuration(for id: String) -> PluginSettings {
        (settings[id] ?? PluginSettings()).applyingDefaults(plugins[id]?.descriptor.defaults ?? PluginSettings())
    }
    public var metadataProviders: [any HostMetadataProvider] { capabilities((any HostMetadataProvider).self) }
    public func capabilities<T>(_ type: T.Type) -> [T] {
        descriptors.filter { contexts[$0.id]?.isActive == true }.flatMap {
            registeredCapabilities[$0.id]?.compactMap { $0 as? T } ?? []
        }
    }
    public func metadataProvider(for id: String) -> (any HostMetadataProvider)? {
        registeredCapabilities[id]?.compactMap { $0 as? any HostMetadataProvider }.first
    }
    public func isActive(_ id: String) -> Bool { contexts[id]?.isActive == true }

    public func configure(_ settings: [String: PluginSettings]) {
        self.settings = settings
        for descriptor in descriptors { reconcile(descriptor.id) }
        updateMetadata()
    }
    public func stopWorkspace() {
        metadata.configure([:])
        metadata.cancelAll()
        for descriptor in descriptors { stop(descriptor.id) }
        // A subsequent activation must never share a previous workspace's identity.
        workspaceID = UUID()
        onChange?()
    }
    public func shutdown() {
        stopWorkspace()
        for descriptor in descriptors { unregister(descriptor.id) }
    }
    private func stop(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        metadata.cancel(providerID: id)
        context.stop()
        plugins[id]?.deactivate()
    }
    private func reconcile(_ id: String) {
        guard let plugin = plugins[id] else { return }
        let configuration = configuration(for: id)
        if let previous = contexts[id] {
            // Layout-only edits do not restart a provider or its CLI queries.
            if configuration.enabled && previous.settings.options == configuration.options &&
                previous.settings.selections == configuration.selections { return }
            stop(id)
        }
        failures[id] = nil
        guard configuration.enabled else { return }
        let context = PluginContext(workspaceID: workspaceID, settings: configuration)
        do { try plugin.activate(context); contexts[id] = context }
        catch {
            context.stop(); plugin.deactivate()
            failures[id] = error.localizedDescription
        }
    }
    private func updateMetadata() {
        var active: [String: PluginSettings] = [:]
        for id in contexts.keys { active[id] = configuration(for: id) }
        metadata.configure(active)
        onChange?()
    }
}
