import Foundation
import Combine
import BozhouCore

public enum MetadataStatus: Equatable {
    case queued, loading, ready, failed(String)
    public var busy: Bool { self == .queued || self == .loading }
}

/// One query at a time per app. Lifecycle tokens reject late replies after disable, deletion or workspace switch.
@MainActor
public final class MetadataCoordinator: ObservableObject {
    @Published public private(set) var statuses: [String: MetadataStatus] = [:]
    public var onSnapshot: ((UUID, MetadataSnapshot) throws -> Void)?
    private var providers: [any HostMetadataProvider]
    private var settings: [String: PluginSettings] = [:]
    private struct Job {
        let key: String
        let subject: MetadataSubject
        let provider: any HostMetadataProvider
        let settings: PluginSettings
    }
    private var queue: [Job] = []
    private var active: (job: Job, token: UUID, task: Task<Void, Never>)?
    private var failedAt: [String: Date] = [:]
    public init(providers: [any HostMetadataProvider] = []) { self.providers = providers }
    func register(_ provider: any HostMetadataProvider) { providers.append(provider) }
    func unregister(_ providerID: String) {
        cancel(providerID: providerID)
        providers.removeAll { $0.id == providerID }
    }
    deinit { active?.task.cancel() }
    public func status(hostID: UUID, providerID: String) -> MetadataStatus? { statuses[key(hostID, providerID)] }
    private func key(_ hostID: UUID, _ providerID: String) -> String { providerID + "/" + hostID.uuidString }

    @discardableResult
    public func configure(_ newSettings: [String: PluginSettings]) -> Bool {
        let changed = providers.contains { provider in
            let a = settings[provider.id] ?? PluginSettings()
            let b = newSettings[provider.id] ?? PluginSettings()
            return a.enabled != b.enabled || a.options != b.options || a.selections != b.selections
        }
        if changed { cancelAll() }
        settings = newSettings
        return changed
    }
    public func cancelAll() {
        active?.task.cancel(); active = nil; queue = []; statuses = [:]; failedAt = [:]
    }
    public func cancel(providerID: String) {
        queue.removeAll { $0.provider.id == providerID }
        if active?.job.provider.id == providerID { active?.task.cancel(); active = nil }
        statuses = statuses.filter { !$0.key.hasPrefix(providerID + "/") }
        failedAt = failedAt.filter { !$0.key.hasPrefix(providerID + "/") }
        pump()
    }
    public func cancel(hostID: UUID) {
        queue.removeAll { $0.subject.hostID == hostID }
        if active?.job.subject.hostID == hostID { active?.task.cancel(); active = nil }
        for provider in providers {
            let id = key(hostID, provider.id); statuses[id] = nil; failedAt[id] = nil
        }
        pump()
    }
    public func request(_ host: BozhouCore.Host, providerID: String? = nil, force: Bool = false, priority: Bool = false) {
        for provider in providers where providerID == nil || provider.id == providerID {
            let configuration = settings[provider.id] ?? PluginSettings()
            guard configuration.enabled else { continue }
            let id = key(host.id, provider.id)
            let subject = MetadataSubject(host: host, providerID: provider.id)
            if let running = active, running.job.key == id, running.job.subject == subject { continue }
            if let index = queue.firstIndex(where: { $0.key == id && $0.subject == subject }) {
                if priority { let job = queue.remove(at: index); queue.insert(job, at: 0) }
                continue
            }
            if !force, let snapshot = host.metadataSnapshot(for: provider.id),
               provider.acceptsCache(snapshot, subject: subject, settings: configuration),
               Date().timeIntervalSince(snapshot.collectedAt) >= 0,
               Date().timeIntervalSince(snapshot.collectedAt) < 900 { continue }
            if !force, let failed = failedAt[id], Date().timeIntervalSince(failed) < 60 { continue }
            queue.removeAll { $0.key == id }
            let job = Job(key: id, subject: subject, provider: provider, settings: configuration)
            if priority { queue.insert(job, at: 0) } else { queue.append(job) }
            statuses[id] = .queued
        }
        pump()
    }
    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst(), token = UUID()
        statuses[job.key] = .loading
        let task = Task { [weak self] in
            do {
                let snapshot = try await job.provider.fetch(job.subject, settings: job.settings)
                try Task.checkCancellation()
                guard let self, active?.token == token else { return }
                guard snapshot.providerID == job.provider.id, snapshot.subjectKey == job.subject.key else {
                    throw BozhouError.invalid(L10n.tr("The plugin returned metadata for a different host."))
                }
                try onSnapshot?(job.subject.hostID, snapshot)
                statuses[job.key] = .ready; failedAt[job.key] = nil
            } catch {
                guard let self, active?.token == token else { return }
                if error is CancellationError { statuses[job.key] = nil }
                else { statuses[job.key] = .failed(error.localizedDescription); failedAt[job.key] = Date() }
            }
            guard let self, active?.token == token else { return }
            active = nil; pump()
        }
        active = (job, token, task)
    }
}
