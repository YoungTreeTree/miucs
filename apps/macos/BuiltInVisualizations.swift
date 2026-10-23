import Foundation

/// Composition root: adding an adapter here never changes audio analysis or the host.
@MainActor
enum BuiltInVisualizations {
    static let defaultID = PencilFlightSimulation.module.id
    static func registry(preferences: UserDefaults = .standard,
                         paletteStore: PencilPaletteStore? = nil) -> VisualizationRegistry {
        let store = paletteStore ?? PencilPaletteStore(preferences: preferences)
        let registry = VisualizationRegistry()
        registry.register(PencilFlightSimulation.module) { MacPencilFlightSession(paletteStore: store) }
        return registry
    }
}
