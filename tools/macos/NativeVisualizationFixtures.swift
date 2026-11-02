import Foundation

/// Legacy renderers remain regression fixtures, never application skin choices.
@MainActor
enum NativeVisualizationFixtures {
    static let defaultID = "pencil-flight"
    static func registry(preferences: UserDefaults = .standard,
                         paletteStore: PencilPaletteStore? = nil) -> VisualizationRegistry {
        let store = paletteStore ?? PencilPaletteStore(preferences: preferences)
        let registry = VisualizationRegistry()
        registry.register(PencilFlightSimulation.module) { MacPencilFlightSession(paletteStore: store) }
        registry.register(StaffNoteSimulation.module) { MacStaffNoteSession() }
        registry.register(MacPixelKeyboardSession.module) { MacPixelKeyboardSession() }
        return registry
    }
}
