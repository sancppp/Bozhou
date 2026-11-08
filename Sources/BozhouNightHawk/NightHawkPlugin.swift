import Foundation
import BozhouCore
import BozhouExtensions

public final class NightHawkPlugin: BozhouPlugin {
    nonisolated public static let environments = ["cn", "sdv", "sg", "idc", "test"]
    nonisolated public static let defaultEnvironments = ["cn", "sdv"]
    public init() {}
    public var descriptor: PluginDescriptor {
        var defaults = PluginSettings()
        defaults.selections["environments"] = Self.defaultEnvironments
        return PluginDescriptor(
            id: NightHawkProvider.identifier, title: L10n.tr("Volcengine ECS metadata · NightHawk"),
            summary: L10n.tr("Uses your locally installed CLI and existing login. Queries saved ECS hosts in the background and caches results for 15 minutes. Disabled by default."),
            help: L10n.tr("Sign in from a local terminal with nighthawk-cli --env <environment> login, then refresh. Bozhou does not install the CLI or change its global configuration."),
            settings: [
                .init("executable", title: L10n.tr("CLI executable"), placeholder: L10n.tr("Auto-detect"), kind: .executable),
                .init("environments", title: L10n.tr("Query environments"), kind: .choices(Self.environments))
            ], defaults: defaults)
    }
    public var capabilities: [any PluginCapability] { [NightHawkProvider()] }
    nonisolated public static var metadataPresentation: MetadataPresentation {
        MetadataPresentation(bindingFields: [
            .init("resource", key: .resourceID, title: L10n.tr("ECS instance ID"), placeholder: L10n.tr("Auto-detect from hostname")),
            .init("region", key: .region, title: L10n.tr("Region"), placeholder: L10n.tr("Auto-detect")),
            .init("account", key: .accountID, title: L10n.tr("Expected account ID"), placeholder: L10n.tr("Optional")),
            .init("environment", key: .environment, title: L10n.tr("Environment"), choices: Self.environments)
        ], bindingHelp: L10n.tr("Automatic matching verifies the hostname's instance ID against its network addresses. For overlapping private IPs or DNS addresses, verify and save an explicit ECS ID. Region and account restrict the result."))
    }
}

public protocol MetadataCommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> Data
}

public enum MetadataFailure: LocalizedError {
    case message(String)
    case rateLimited(String?)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .rateLimited(let id):
            return L10n.tr("NightHawk rate limit reached. Queries pause for 60 seconds before retrying.")
                + (id.map { "\n" + L10n.tr("Request ID: \($0)") } ?? "")
        }
    }
}
