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

        var fixedHeights = true, trueNames = true, fixedClef = true
        for midi in [43, 48, 55, 60, 71, 84] {
            let fixed = StaffNotePreview.sampleScene(midi: Double(midi)), expected = StaffPitch(midi: midi)!.y
            let v = StaffNoteView(preview: fixed); v.wantsLayer = true; v.updateLayer()
            let layers = v.layer!.sublayers!.first!.sublayers!
            let head = layers.first { $0.name == "music-note" }!
            let marker = layers.first { $0.name == "pitch-marker" }!
            let name = layers.first { $0.name == "pitch-label" } as! CATextLayer
            fixedHeights = fixedHeights && abs(head.position.y - expected) < 0.001 && marker.position.y == expected
            trueNames = trueNames && (name.string as? NSAttributedString)?.string == StaffPitch(midi: midi)?.name
            fixedClef = fixedClef && !layers.contains { $0.name == "clef-octave" } && layers.filter { $0 is CATextLayer }.count == 2
            for retained in [false, true] {
                let b = StaffNotePreview.bitmap(scene: fixed, width: 800, retainedLayers: retained)
                fixedHeights = fixedHeights && b.colorAt(x: 1280, y: Int(expected * 2))!.alphaComponent > 0.9
            }
        }
        check("Native and reference renderers place low and high notes at fixed absolute staff heights", fixedHeights)
        check("Fixed staff positions keep their true sounding pitch labels", trueNames)
        check("The treble clef has no changing octave-transposition label", fixedClef)

        var repeatedC4 = true, historyFixed = true
        for preceding in [43.0, 84] {
            var phrase = StaffNotePreview.sampleScene(midi: preceding)
            for _ in 0..<120 {
                phrase.advance(seconds: 1.0 / 60); phrase.receive(audio: StaffNotePreview.audio(phrase.elapsed))
                phrase.receive(melody: StaffNotePreview.melody(phrase.elapsed, midi: 60))
            }
            let v = StaffNoteView(preview: phrase); v.wantsLayer = true; v.updateLayer()
            let root = v.layer!.sublayers!.first!, head = root.sublayers!.first { $0.name == "music-note" }!
            repeatedC4 = repeatedC4 && abs(head.position.y - 98) < 0.001
            let oldC4 = phrase.trace.last!
            for _ in 0..<180 {
                phrase.advance(seconds: 1.0 / 60); phrase.receive(audio: StaffNotePreview.audio(phrase.elapsed))
                phrase.receive(melody: StaffNotePreview.melody(phrase.elapsed, midi: 48))
            }
            v.updatePreview(phrase); v.updateLayer()
            let trail = root.sublayers!.first { $0.name == "melody-trail" }!
            let path = (trail.sublayers!.last as! CAShapeLayer).path!
            let oldX = phrase.traceX(oldC4) - 80
            var hasOriginalHeight = false
            path.applyWithBlock { element in
                if element.pointee.type == .addLineToPoint || element.pointee.type == .moveToPoint {
                    let p = element.pointee.points[0]
                    if abs(p.x - oldX) < 0.001 && abs(p.y - 98) < 0.001 { hasOriginalHeight = true }
                }
            }
            historyFixed = historyFixed && hasOriginalHeight
        }
        check("The rendered C4 head uses the same height after low and high musical contexts", repeatedC4)
        check("A later low phrase leaves old C4 pixels at their original staff height", historyFixed)

        var bridging = StaffNoteScene()
        bridging.receive(audio: StaffNotePreview.audio(0)); bridging.receive(melody: StaffNotePreview.melody(0, midi: 71))
        bridging.advance(seconds: 0.1); bridging.receive(audio: StaffNotePreview.audio(0.1)); bridging.receive(melody: nil)
        let contourView = StaffNoteView(preview: bridging); contourView.wantsLayer = true; contourView.updateLayer()
        func contourPath() -> CGPath {
            let root = contourView.layer!.sublayers!.first!
            let trail = root.sublayers!.first { $0.name == "melody-trail" }!
            return (trail.sublayers!.last as! CAShapeLayer).path!
        }
        func segments(_ path: CGPath) -> Int {
            var count = 0
            path.applyWithBlock { if $0.pointee.type == .moveToPoint { count += 1 } }
            return count
        }
        check("The rendered live contour reaches the note while a brief invalid sample is filtered",
            contourPath().currentPoint == CGPoint(x: 560, y: 74) && bridging.trace.count == 1)
        bridging.advance(seconds: 0.02); bridging.receive(audio: StaffNotePreview.audio(0.12))
        bridging.receive(melody: StaffNotePreview.melody(0.12, midi: 72))
        contourView.updatePreview(bridging); contourView.updateLayer()
        check("The native trace has one continuous subpath across a short filtered interval", segments(contourPath()) == 1)
        var followsHead = true
        for tick in 0..<45 {
            bridging.advance(seconds: 1.0 / 60); bridging.receive(audio: StaffNotePreview.audio(bridging.elapsed))
            bridging.receive(melody: tick < 12 ? StaffNotePreview.melody(bridging.elapsed, midi: 72) : nil)
            contourView.updatePreview(bridging); contourView.updateLayer()
            followsHead = followsHead && (bridging.hasContinuousTraceTail ?
                contourPath().currentPoint == CGPoint(x: 560, y: bridging.noteY) : contourPath().currentPoint.x < 560) && segments(contourPath()) == 1
        }
        check("The native contour joins live motion but stops extending when pitch becomes stale", followsHead && !bridging.hasContinuousTraceTail)
        bridging.receive(melody: StaffNotePreview.melody(bridging.elapsed, midi: 71))
        contourView.updatePreview(bridging); contourView.updateLayer()
        let detachedBeforeJoin = segments(contourPath()) > 1
        var settledBridge = bridging
        for _ in 0..<20 {
            settledBridge.advance(seconds: 0.02); settledBridge.receive(audio: StaffNotePreview.audio(settledBridge.elapsed))
            settledBridge.receive(melody: StaffNotePreview.melody(settledBridge.elapsed, midi: 71))
        }
        contourView.updatePreview(settledBridge); contourView.updateLayer()
        check("A model-only gap joins progressively and settles into one continuous native subpath",
              detachedBeforeJoin && segments(contourPath()) == 1)
        bridging = settledBridge
        // Give this phrase a real line segment. CGPath coalesces consecutive
        // move-only subpaths, so a single sample is not a drawable segment.
        bridging.advance(seconds: 0.02); bridging.receive(audio: StaffNotePreview.audio(bridging.elapsed))
        bridging.receive(melody: StaffNotePreview.melody(bridging.elapsed, midi: 71))
        bridging.receive(audio: StaffNotePreview.audio(bridging.elapsed, silent: true))
        bridging.advance(seconds: 0.02); bridging.receive(audio: StaffNotePreview.audio(bridging.elapsed))
        bridging.receive(melody: StaffNotePreview.melody(bridging.elapsed, midi: 71))
        contourView.updatePreview(bridging); contourView.updateLayer()
        check("The native trace still separates actual silence", segments(contourPath()) == 2)

        var neuralContour = StaffNoteScene()
        func sung(_ time: Double, _ midi: Double?) -> MelodyFrame {
            MelodyFrame(time: time, pitchHz: midi.map { 440 * pow(2, ($0 - 69) / 12) },
                confidence: midi == nil ? 0 : 0.35, isMelodic: midi != nil, estimator: .crepe)
        }
        for hop in 0...1 {
            neuralContour.receive(audio: StaffNotePreview.audio(Double(hop) * 0.02))
            neuralContour.receive(melody: sung(Double(hop) * 0.02, 71))
            neuralContour.advance(seconds: 0.02)
        }
        neuralContour.receive(audio: StaffNotePreview.audio(0.04)); neuralContour.receive(melody: sung(0.04, nil))
        contourView.updatePreview(neuralContour); contourView.updateLayer()
        check("A neural dropout draws only existing history, with no held-note horizontal extension",
            contourPath().currentPoint.x < 560 && neuralContour.trace.count == 2 && !neuralContour.hasContinuousTraceTail)
        neuralContour.advance(seconds: 0.06); neuralContour.receive(audio: StaffNotePreview.audio(0.10))
        neuralContour.receive(melody: sung(0.10, 72))
        contourView.updatePreview(neuralContour); contourView.updateLayer()
        check("An 80ms neural gap starts joining from its real endpoints while the live path reaches the note",
            segments(contourPath()) == 2 && neuralContour.trace.count == 3 && contourPath().currentPoint.x == 560)
        neuralContour.advance(seconds: 0.02); neuralContour.receive(audio: StaffNotePreview.audio(0.12))
        neuralContour.receive(melody: sung(0.12, nil))
        neuralContour.advance(seconds: 0.14); neuralContour.receive(audio: StaffNotePreview.audio(0.26))
        neuralContour.receive(melody: sung(0.26, 72))
        contourView.updatePreview(neuralContour); contourView.updateLayer()
        let multipleJoins = segments(contourPath()) > 1
        var settledNeural = neuralContour; settledNeural.advance(seconds: 0.35)
        contourView.updatePreview(settledNeural); contourView.updateLayer()
        check("Overlapping neural gap joins settle back into one native path", multipleJoins && segments(contourPath()) == 1)

        var gradual = StaffNotePreview.sampleScene(midi: 71)
        gradual.receive(melody: sung(gradual.elapsed, nil))
        for _ in 0..<45 {
            gradual.advance(seconds: 1.0 / 60)
            gradual.receive(audio: StaffNotePreview.audio(gradual.elapsed))
            gradual.receive(melody: sung(gradual.elapsed, nil))
        }
        gradual.receive(melody: sung(gradual.elapsed + 0.001, 60))
        let joinDirectory = URL(fileURLWithPath: "build/staff-join-preview")
        try FileManager.default.createDirectory(at: joinDirectory, withIntermediateDirectories: true)
        var joinPaths = [CGPath]()
        for (name, delay) in [("arrival", 0.0), ("early", 0.05), ("middle", 0.07), ("settled", 0.20)] {
            gradual.advance(seconds: delay); gradual.receive(audio: StaffNotePreview.audio(gradual.elapsed))
            contourView.updatePreview(gradual); contourView.updateLayer(); joinPaths.append(contourPath())
            let bitmap = StaffNotePreview.bitmap(scene: gradual, width: 800, background: .white, retainedLayers: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: joinDirectory.appendingPathComponent(name + ".png"))
        }
        func curveCount(_ path: CGPath) -> Int {
            var count = 0
            path.applyWithBlock { if $0.pointee.type == .addCurveToPoint { count += 1 } }
            return count
        }
        check("Native reconnection grows curved tips before closing the gap, with a smooth final curve",
              curveCount(joinPaths[0]) == 0 && curveCount(joinPaths[1]) == 2 &&
              curveCount(joinPaths[2]) == 2 && curveCount(joinPaths[3]) == 1 && segments(joinPaths[3]) == 1)

        var extraLinesAbsent = true, keepsFiveLines = true
        for midi in [48.0, 84] {
            var outside = StaffNotePreview.sampleScene(midi: 71)
            for _ in 0..<20 {
                outside.advance(seconds: 1.0 / 60)
                outside.receive(audio: StaffNotePreview.audio(outside.elapsed))
                outside.receive(melody: StaffNotePreview.melody(outside.elapsed, midi: midi))
            }
            // High and low notes retain their real staff height without extra ledger strokes.
            extraLinesAbsent = extraLinesAbsent && outside.pitch?.midi == Int(midi) && outside.targetY == StaffPitch(midi: Int(midi))!.y
            for width in [600, 800, 1600] {
                for retained in [false, true] {
                    let b = StaffNotePreview.bitmap(scene: outside, width: width, retainedLayers: retained)
                    let scale = Double(width) / 400
                    for y in midi < 71 ? [98.0, 106, 114] : [50.0] {
                        extraLinesAbsent = extraLinesAbsent && b.colorAt(x: Int(631 * scale), y: Int(y * scale))!.alphaComponent == 0
                    }
                    for y in [58.0, 66, 74, 82, 90] {
                        keepsFiveLines = keepsFiveLines && b.colorAt(x: Int(750 * scale), y: Int(y * scale))!.alphaComponent > 0.1
                    }
                    if width == 800 {
                        let file = "build/staff-no-ledgers-\(Int(midi))-\(retained ? "native" : "reference").png"
                        try b.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
                    }
                }
            }
        }
        check("High and low notes have no extra short horizontal lines in either renderer at all three sizes", extraLinesAbsent)
        check("Removing ledger strokes preserves all five main staff lines", keepsFiveLines)

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
        for midi in [43.0, 84] {
            let edgeScene = StaffNotePreview.sampleScene(midi: midi)
            withinCanvas = withinCanvas && edgeScene.pitch?.midi == Int(midi)
            let edge = StaffNotePreview.bitmap(scene: edgeScene, width: 800)
            // Check the character's strip only; staff lines intentionally span the drawing.
            for x in 1230..<1330 {
                for y in [0, 1, 318, 319] { withinCanvas = withinCanvas && edge.colorAt(x: x, y: y)!.alphaComponent == 0 }
            }
        }
        check("G2 and C6 note bodies, stems and flags remain inside the canvas", withinCanvas)
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
