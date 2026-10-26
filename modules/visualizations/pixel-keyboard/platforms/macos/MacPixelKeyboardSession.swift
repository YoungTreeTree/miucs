import AppKit

@MainActor
final class MacPixelKeyboardSession: MacVisualizationSession {
    static let module = VisualizationDescriptor(id: "pixel-keyboard", name: "像素音乐键盘",
        layout: VisualizationLayout(width: 800, height: 460, minimumWidth: 80, maximumWidth: 1600))
    let music = StaffNoteSimulation(keyboardKeys: MacStaffKeyboardLayout.keys)
    let drawing = PixelKeyboardView(frame: NSRect(x: 0, y: 0, width: 800, height: 460))
    private(set) var keyboard = PixelKeyboardScene(codes: MacStaffKeyboardLayout.keys)
    private var pendingKeyboard: KeyboardInput?
    private var active = false
    var descriptor: VisualizationDescriptor { Self.module }
    var view: NSView { drawing }
    var settingsTitle: String? { nil }
    private(set) var hintColor = VisualizationAppearance.graphite.ink.nsColor
    func activate(viewport: VisualizationViewport) {
        active = true; keyboard.reset(); pendingKeyboard = nil
        music.activate(viewport: viewport); presentMusic(); drawing.present(keyboard)
    }
    func resize(to viewport: VisualizationViewport) { music.resize(to: viewport) }
    func applyAppearance(_ appearance: VisualizationAppearance) {
        drawing.applyAppearance(appearance); hintColor = appearance.ink.nsColor
    }
    func receive(keyboard: KeyboardInput) {
        guard active else { return }
        pendingKeyboard = keyboard; music.receive(keyboard: keyboard)
    }
    func update(input: FeatureInput, deltaTime: Double) {
        guard active else { return }
        if keyboard.advance(seconds: deltaTime, input: pendingKeyboard) { drawing.present(keyboard) }
        pendingKeyboard = nil
        music.update(input: input, deltaTime: deltaTime)
        if music.needsDisplay { presentMusic() }
    }
    private func presentMusic() {
        drawing.staff.updatePreview(music.scene, stars: music.keyboardStars.stars, rings: music.beatRings.rings)
        drawing.staff.updateLayer()
    }
    func deactivate() {
        active = false; music.deactivate(); keyboard.reset(); pendingKeyboard = nil
        drawing.present(keyboard); presentMusic()
    }
    func dispose() { deactivate() }
    func presentSettings() {}
}
