import Foundation

/// Composition root: adding an adapter here never changes audio analysis or the host.
@MainActor
enum BuiltInVisualizations {
    static let defaultID = PencilFlightSimulation.module.id
    static func registry(preferences: UserDefaults = .standard,
                         paletteStore: PencilPaletteStore? = nil) -> VisualizationRegistry {
        let store = paletteStore ?? PencilPaletteStore(preferences: preferences)
        let registry = VisualizationRegistry()
        if PluginHost.enabled {
            PluginHost.shared.register(in: registry)
            return registry
        }
        registry.register(PencilFlightSimulation.module) { MacPencilFlightSession(paletteStore: store) }
        registry.register(StaffNoteSimulation.module) { MacStaffNoteSession() }
        registry.register(MacPixelKeyboardSession.module) { MacPixelKeyboardSession() }
        return registry
    }
}
