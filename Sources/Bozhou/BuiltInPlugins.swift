import BozhouExtensions
import BozhouNightHawk

/// The app's only vendor-specific composition point.
@MainActor
enum BuiltInPlugins {
    static func register(in registry: PluginRegistry) throws {
        try registry.register(NightHawkPlugin())
    }
}
