import AppKit

@MainActor
final class MacStaffNoteSession: MacVisualizationSession {
    let simulation = StaffNoteSimulation(keyboardKeys: MacStaffKeyboardLayout.keys)
    let drawing = StaffNoteView()
    var descriptor: VisualizationDescriptor { StaffNoteSimulation.module }
    var view: NSView { drawing }
    var settingsTitle: String? { nil }
    private(set) var hintColor = VisualizationAppearance.graphite.ink.nsColor
    init() {
        drawing.wantsLayer = true
        drawing.layer?.isOpaque = false; drawing.layer?.backgroundColor = NSColor.clear.cgColor
    }
    func activate(viewport: VisualizationViewport) {
        simulation.activate(viewport: viewport)
        drawing.updatePreview(simulation.scene, stars: simulation.keyboardStars.stars, rings: simulation.beatRings.rings)
        drawing.needsDisplay = true
    }
    func applyAppearance(_ appearance: VisualizationAppearance) {
        drawing.applyAppearance(appearance); hintColor = appearance.ink.nsColor
    }
    func resize(to viewport: VisualizationViewport) { simulation.resize(to: viewport); drawing.needsDisplay = true }
    func receive(keyboard: KeyboardInput) { simulation.receive(keyboard: keyboard) }
    func update(input: FeatureInput, deltaTime: Double) {
        simulation.update(input: input, deltaTime: deltaTime)
        if simulation.needsDisplay {
            drawing.updatePreview(simulation.scene, stars: simulation.keyboardStars.stars, rings: simulation.beatRings.rings)
            drawing.needsDisplay = true
        }
    }
    func deactivate() { simulation.deactivate() }
    func dispose() { deactivate() }
    func presentSettings() {}
}
