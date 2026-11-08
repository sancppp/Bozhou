import Foundation
import BozhouCore

public protocol HostMetadataProvider: PluginCapability {
    var id: String { get }
    var title: String { get }
    var presentation: MetadataPresentation { get }
    func acceptsCache(_ snapshot: MetadataSnapshot, subject: MetadataSubject, settings: PluginSettings) -> Bool
    func fetch(_ subject: MetadataSubject, settings: PluginSettings) async throws -> MetadataSnapshot
}

extension HostMetadataProvider {
    public var presentation: MetadataPresentation { MetadataPresentation() }
    public func acceptsCache(_ snapshot: MetadataSnapshot, subject: MetadataSubject, settings: PluginSettings) -> Bool { true }
}

public struct MetadataBindingField: Identifiable, Sendable {
    public enum Key: Sendable { case resourceID, region, accountID, environment }
    public var id: String
    public var key: Key
    public var title: String
    public var placeholder: String
    public var choices: [String]?
    public init(_ id: String, key: Key, title: String, placeholder: String = "", choices: [String]? = nil) {
        self.id = id; self.key = key; self.title = title; self.placeholder = placeholder; self.choices = choices
    }
    public var keyPath: WritableKeyPath<MetadataBinding, String> {
        switch key {
        case .resourceID: return \.resourceID
        case .region: return \.region
        case .accountID: return \.accountID
        case .environment: return \.environment
        }
    }
}

public struct MetadataPresentation: Sendable {
    public var bindingFields: [MetadataBindingField]
    public var bindingHelp: String
    public init(bindingFields: [MetadataBindingField] = [], bindingHelp: String = "") {
        self.bindingFields = bindingFields; self.bindingHelp = bindingHelp
    }
}
