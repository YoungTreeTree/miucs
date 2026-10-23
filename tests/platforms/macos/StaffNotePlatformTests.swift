import AppKit

@MainActor
private final class LayoutProbe: MacVisualizationSession {
    let descriptor: VisualizationDescriptor
    let view = NSView()
    var settingsTitle: String? { nil }
    var activations = [VisualizationViewport]()
    var disposed = false
    init(_ descriptor: VisualizationDescriptor) { self.descriptor = descriptor }
    func activate(viewport: VisualizationViewport) { activations.append(viewport) }
    func resize(to viewport: VisualizationViewport) {}
    func update(input: FeatureInput, deltaTime: Double) {}
    func deactivate() {}
    func dispose() { disposed = true }
    func presentSettings() {}
}

@main
@MainActor
enum StaffNotePlatformTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        let suite = "MiucsStaffPlatform-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        let registry = VisualizationRegistry()
        var flight: LayoutProbe?, staff: LayoutProbe?
        registry.register(PencilFlightSimulation.module) { let p = LayoutProbe(PencilFlightSimulation.module); flight = p; return p }
        registry.register(StaffNoteSimulation.module) { let p = LayoutProbe(StaffNoteSimulation.module); staff = p; return p }
        let channel = FeatureChannel(), visible = NSScreen.main!.visibleFrame
        let origin = NSPoint(x: visible.minX + 30, y: visible.maxY - 320)
        preferences.set(["x": origin.x, "y": origin.y, "width": 400.0, "height": 260.0], forKey: "MiucsPencilFlightFrame")
        let panel = VisualizerPanel(source: channel, registry: registry, preferences: preferences, persistsFrame: false)
        defer { panel.orderOut(nil); panel.visualizationHost.dispose() }
        check("Legacy flight preference keys and 400x260 layout remain compatible", panel.frame == NSRect(origin: origin, size: NSSize(width: 400, height: 260)) && panel.descriptor.id == "pencil-flight")
        panel.orderFrontRegardless()
        let old = flight!, flightFrame = panel.frame
        let anchor = NSPoint(x: flightFrame.minX, y: flightFrame.maxY)
        let selected = panel.selectVisualization(id: "staff-note")
        check("First staff switch uses 800x160 and keeps the old upper-left anchor", selected && panel.frame.width == 800 && panel.frame.height == 160 && panel.frame.minX == anchor.x && panel.frame.maxY == anchor.y)
        check("New session activates only after its own viewport is restored", staff?.activations == [VisualizationViewport(width: 800, height: 160, scale: 1)] && old.disposed)
        check("Module selection is persisted", preferences.string(forKey: VisualizerPanel.selectionPreferencesKey) == "staff-note")
        check("The long panel stays transparent and mouse click-through", !panel.isOpaque && panel.backgroundColor?.alphaComponent == 0 && !panel.hasShadow && panel.ignoresMouseEvents)
        panel.setDrawingWidth(900)
        panel.setFrameOrigin(NSPoint(x: visible.minX + 50, y: visible.minY + 100)); panel.saveDrawingFrame()
        let staffFrame = panel.frame
        check("Staff scaling uses the 5:1 ratio and logical 800-point width", staffFrame.height == 180 && panel.drawingScale == 1.125 && panel.visualizationHost.activeView?.bounds.size == staffFrame.size)
        _ = panel.selectVisualization(id: "pencil-flight")
        check("Switching back restores flight's independent position and size", panel.frame == flightFrame && panel.drawingAspectRatio == 0.65)
        _ = panel.selectVisualization(id: "staff-note")
        check("Returning to staff restores its independent position and size", panel.frame == staffFrame && staff?.activations.last == VisualizationViewport(width: 900, height: 180, scale: 1.125))
        let same = staff, saved = panel.frame
        check("Same or unknown module leaves its current geometry/session intact", panel.selectVisualization(id: "staff-note") && !panel.selectVisualization(id: "missing") && staff === same && panel.frame == saved)
        let reopened = VisualizerPanel(source: channel, registry: registry, preferences: preferences, persistsFrame: false)
        check("Reopening remembers the selected module and its saved rectangle", reopened.descriptor.id == "staff-note" && reopened.frame == staffFrame && reopened.ignoresMouseEvents)
        reopened.visualizationHost.dispose()
        panel.setDrawingWidth(10)
        check("Staff has a readable minimum width of 600 points", panel.frame.width == min(600, visible.width) && abs(panel.frame.height * 5 - panel.frame.width) < 1e-8)
        panel.setDrawingWidth(100_000)
        check("Staff maximum is screen-constrained and never exceeds 1600 points", panel.frame.width <= 1600 && visible.insetBy(dx: -0.1, dy: -0.1).contains(panel.frame) && abs(panel.frame.height * 5 - panel.frame.width) < 1e-8)
        panel.setAdjustingPosition(true)
        let resizeAnchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setDrawingWidth(700, topLeft: resizeAnchor, persist: false)
        check("Long-layout resizing keeps the upper-left anchor and accepts adjustment input", panel.frame.minX == resizeAnchor.x && panel.frame.maxY == resizeAnchor.y && panel.frame.height == 140 && !panel.ignoresMouseEvents)
        panel.setAdjustingPosition(false)
        check("Finishing adjustment restores mouse transparency", panel.ignoresMouseEvents)
        panel.orderOut(nil); _ = panel.selectVisualization(id: "pencil-flight")
        check("Changing a hidden module does not activate rendering", !panel.visualizationHost.controller.isActive && flight?.activations.isEmpty == true)
        preferences.set("unknown-future-module", forKey: VisualizerPanel.selectionPreferencesKey)
        let fallback = VisualizerPanel(source: channel, registry: registry, preferences: preferences, persistsFrame: false)
        check("Unknown saved identifiers fall back to flight", fallback.descriptor.id == "pencil-flight")
        fallback.visualizationHost.dispose()
        let builtins = BuiltInVisualizations.registry(preferences: preferences)
        let native = builtins.makeSession(id: "staff-note") as? MacStaffNoteSession
        check("Both production modules are registered and staff has no palette panel", builtins.descriptors.map(\.id) == ["pencil-flight", "staff-note"] && native?.settingsTitle == nil && native?.view is StaffNoteView)
        let generation = UUID()
        native?.activate(viewport: VisualizationViewport(width: 800, height: 160, scale: 1))
        let snapshot = AudioFeatureFrame(sessionID: generation, sequence: 1, receivedAt: 0,
            audio: StaffNotePreview.audio(0), melody: StaffNotePreview.melody(0, midi: 60))
        native?.update(input: FeatureInput(sessionID: generation, state: .running, frame: snapshot,
            frameAge: 0, onsets: [], spectralFluxPeak: 0), deltaTime: 1.0 / 60)
        let hadTrace = native?.drawing.scene.trace.count == 1
        native?.deactivate(); native?.activate(viewport: VisualizationViewport(width: 800, height: 160, scale: 1))
        check("First redraw after native resume cannot display a cached old trajectory", hadTrace && native?.drawing.scene.trace.isEmpty == true)
        native?.dispose()

        var pivot = StaffNoteScene()
        for _ in 0..<120 {
            pivot.receive(audio: StaffNotePreview.audio(pivot.elapsed))
            pivot.receive(melody: StaffNotePreview.melody(pivot.elapsed, midi: 71))
            pivot.advance(seconds: 1.0 / 60)
        }
        // Compare the same instant so trail aging and volume easing cannot affect head pixels.
        var uprightScene = pivot
        uprightScene.advance(seconds: 0.1)
        let upright = StaffNotePreview.bitmap(scene: uprightScene, width: 800)
        var tilted = pivot
        tilted.receiveOnset(strength: 0.8); tilted.advance(seconds: 0.1)
        let leaning = StaffNotePreview.bitmap(scene: tilted, width: 800)
        var fixedHead = true, changedStemPixels = 0
        for y in 147..<150 {
            for x in 1277..<1283 {
                fixedHead = fixedHead && upright.colorAt(x: x, y: y)!.isEqual(leaning.colorAt(x: x, y: y)!)
            }
        }
        for y in 90..<138 {
            for x in 1245..<1320 {
                if !upright.colorAt(x: x, y: y)!.isEqual(leaning.colorAt(x: x, y: y)!) { changedStemPixels += 1 }
            }
        }
        if !fixedHead || changedStemPixels <= 100 {
            print("Pivot render details: fixedHead=\(fixedHead), changedStemPixels=\(changedStemPixels), angle=\(tilted.swayAngle), head=(\(tilted.noteCenterX), \(tilted.noteY))")
            try upright.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/staff-pivot-upright.png"))
            try leaning.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/staff-pivot-leaning.png"))
        }
        check("Production drawing tilts the stem around an unchanged solid head", fixedHead && changedStemPixels > 100 &&
            abs(tilted.swayAngle) > 10 * .pi / 180 && tilted.noteCenterX == pivot.noteCenterX && tilted.noteY == pivot.noteY)

        let layerUpright = StaffNotePreview.bitmap(scene: uprightScene, width: 800, retainedLayers: true)
        let layerLeaning = StaffNotePreview.bitmap(scene: tilted, width: 800, retainedLayers: true)
        var layerHeadFixed = true, layerStemChanges = 0
        for y in 147..<150 {
            for x in 1277..<1283 {
                layerHeadFixed = layerHeadFixed && layerUpright.colorAt(x: x, y: y)!.isEqual(layerLeaning.colorAt(x: x, y: y)!)
            }
        }
        for y in 90..<138 {
            for x in 1245..<1320 {
                if !layerUpright.colorAt(x: x, y: y)!.isEqual(layerLeaning.colorAt(x: x, y: y)!) { layerStemChanges += 1 }
            }
        }
        check("Retained native layers preserve the same pivot and rotating stem", layerHeadFixed && layerStemChanges > 100 &&
            layerUpright.colorAt(x: 1280, y: 148)!.alphaComponent > 0.9)

        let scene = StaffNotePreview.sampleScene()
        let bitmap = StaffNotePreview.bitmap(scene: scene, width: 800)
        let repeated = StaffNotePreview.bitmap(scene: scene, width: 800)
        let data = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let repeatedData = Data(bytes: repeated.bitmapData!, count: repeated.bytesPerRow * repeated.pixelsHigh)
        check("Identical scene redraws have byte-identical pencil marks", data == repeatedData)
        var transparent = 0, translucent = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
                if alpha == 0 { transparent += 1 }
                if alpha > 0 && alpha < 1 { translucent += 1 }
            }
        }
        check("Canvas remains mostly transparent with antialiased pencil lines", Double(transparent) / Double(bitmap.pixelsHigh * bitmap.pixelsWide) > 0.85 && translucent > 3000)
        let light = StaffNotePreview.bitmap(scene: scene, width: 800, background: NSColor(calibratedWhite: 0.96, alpha: 1))
        let dark = StaffNotePreview.bitmap(scene: scene, width: 800, background: NSColor(calibratedWhite: 0.12, alpha: 1))
        let lightLine = light.colorAt(x: 1000, y: 148)!.usingColorSpace(.deviceRGB)!
        let darkLine = dark.colorAt(x: 1000, y: 148)!.usingColorSpace(.deviceRGB)!
        check("Graphite and pale underlines are visible on light and dark backgrounds", lightLine.redComponent < 0.85 && darkLine.redComponent > 0.16)
        var withinCanvas = true
        for midi in [40.0, 96] {
            let edge = StaffNotePreview.bitmap(scene: StaffNotePreview.sampleScene(midi: midi), width: 800)
            // Check the character's strip only; staff lines intentionally span the drawing.
            for x in 1230..<1330 {
                for y in [0, 1, 318, 319] { withinCanvas = withinCanvas && edge.colorAt(x: x, y: y)!.alphaComponent == 0 }
            }
        }
        check("E2 and C7 note bodies, stems and flags remain inside the canvas", withinCanvas)
        let small = StaffNotePreview.bitmap(scene: scene, width: 600)
        let large = StaffNotePreview.bitmap(scene: scene, width: 1600)
        check("Minimum and maximum sizes render uniformly at 2x backing scale", small.pixelsWide == 1200 && small.pixelsHigh == 240 && large.pixelsWide == 3200 && large.pixelsHigh == 640)
        try StaffNotePreview.render(to: URL(fileURLWithPath: "build/staff-note-preview"))

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/staff-note-platform-tests.json"))
        if failures > 0 { exit(1) }
    }
}
