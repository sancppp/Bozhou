import Foundation

/// Persisted options are namespaced by plugin ID. Never store credentials here.
public struct PluginSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var options: [String: String] = [:]
    public var selections: [String: [String]] = [:]
    /// Used only by plugins contributing host metadata.
    public var layout = MetadataLayout()
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, options, selections, layout }
    private enum LegacyKeys: String, CodingKey { case executable, environments }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        options = try values.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        selections = try values.decodeIfPresent([String: [String]].self, forKey: .selections) ?? [:]
        layout = try values.decodeIfPresent(MetadataLayout.self, forKey: .layout) ?? MetadataLayout()
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if options["executable"] == nil { options["executable"] = try legacy.decodeIfPresent(String.self, forKey: .executable) }
        if selections["environments"] == nil { selections["environments"] = try legacy.decodeIfPresent([String].self, forKey: .environments) }
    }

    public func applyingDefaults(_ defaults: Self) -> Self {
        var result = self
        result.options = defaults.options.merging(options) { _, saved in saved }
        result.selections = defaults.selections.merging(selections) { _, saved in saved }
        return result
    }
}
