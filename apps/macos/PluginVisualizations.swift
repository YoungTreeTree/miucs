import Foundation

/// The catalog is the only source of visualization sessions.
@MainActor
enum PluginVisualizations {
    static let defaultID = "pencil-flight"
    static func registry() -> VisualizationRegistry {
        let registry = VisualizationRegistry()
        PluginHost.shared.register(in: registry)
        return registry
    }
}
