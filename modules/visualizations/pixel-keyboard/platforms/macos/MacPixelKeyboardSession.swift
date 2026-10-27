import AppKit

@MainActor
final class MacPixelKeyboardSession: MacVisualizationSession {
    static let module = VisualizationDescriptor(id: "pixel-keyboard", name: "像素音乐键盘",
        layout: VisualizationLayout(width: 800, height: 460, minimumWidth: 80, maximumWidth: 1600))
    private(set) var tail = PixelTailScene()
    private(set) var head = PixelHeadScene()
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
        tail.reset(); head.reset(); drawing.presentHead(head); drawing.presentTail(tail); drawing.present(keyboard)
    }
    func resize(to viewport: VisualizationViewport) {}
    func applyAppearance(_ appearance: VisualizationAppearance) {
        drawing.applyAppearance(appearance); hintColor = appearance.ink.nsColor
    }
    func receive(keyboard: KeyboardInput) {
        guard active else { return }
        pendingKeyboard = keyboard
    }
    func update(input: FeatureInput, deltaTime: Double) {
        guard active else { return }
        if keyboard.advance(seconds: deltaTime, input: pendingKeyboard) { drawing.present(keyboard) }
        if head.advance(seconds: deltaTime, input: pendingKeyboard) { drawing.presentHead(head) }
        pendingKeyboard = nil
        if tail.advance(input, seconds: deltaTime) { drawing.presentTail(tail) }
    }
    func deactivate() {
        active = false; tail.reset(); head.reset(); keyboard.reset(); pendingKeyboard = nil
        drawing.present(keyboard); drawing.presentHead(head); drawing.presentTail(tail)
    }
    func dispose() { deactivate() }
    func presentSettings() {}
}
