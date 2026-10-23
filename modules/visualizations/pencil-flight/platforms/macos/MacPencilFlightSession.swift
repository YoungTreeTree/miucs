import AppKit
import Combine

@MainActor
final class MacPencilFlightSession: MacVisualizationSession {
    let simulation = PencilFlightSimulation()
    let drawing: PencilFlightView
    private let paletteStore: PencilPaletteStore
    private var subscription: AnyCancellable?
    private var settingsWindow: PaletteWindowController?
    var descriptor: VisualizationDescriptor { PencilFlightSimulation.module }
    var view: NSView { drawing }
    var settingsTitle: String? { "调色盘…" }
    private(set) var hintColor: NSColor
    init(paletteStore: PencilPaletteStore) {
        self.paletteStore = paletteStore
        hintColor = paletteStore.palette.notes.nsColor
        drawing = PencilFlightView(preview: simulation.world, palette: paletteStore.palette)
        drawing.wantsLayer = true
        drawing.layer?.isOpaque = false; drawing.layer?.backgroundColor = NSColor.clear.cgColor
        subscription = paletteStore.$palette.sink { [weak self] palette in
            self?.drawing.updatePalette(palette); self?.hintColor = palette.notes.nsColor
        }
    }
    func activate(viewport: VisualizationViewport) { simulation.activate(viewport: viewport); drawing.needsDisplay = true }
    func resize(to viewport: VisualizationViewport) { simulation.resize(to: viewport); drawing.needsDisplay = true }
    func update(input: FeatureInput, deltaTime: Double) {
        simulation.update(input: input, deltaTime: deltaTime)
        if simulation.needsDisplay { drawing.updatePreview(simulation.world); drawing.needsDisplay = true }
    }
    func deactivate() { simulation.deactivate() }
    func dispose() { deactivate(); settingsWindow?.close(); settingsWindow = nil; subscription?.cancel() }
    func presentSettings() {
        if settingsWindow == nil { settingsWindow = PaletteWindowController(store: paletteStore) }
        settingsWindow?.present()
    }
}
