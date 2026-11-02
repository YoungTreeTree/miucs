import Foundation

/// Composition root: adding an adapter here never changes audio analysis or the host.
@MainActor
enum BuiltInVisualizations {
    static let defaultID = "pixel-keyboard"
    static func registry(userDirectory: String? = nil) -> VisualizationRegistry {
        let registry = VisualizationRegistry()
        PluginHost.shared.register(in: registry, excluding: SkinItem.retiredIDs, userDirectory: userDirectory)
        return registry
    }
}
