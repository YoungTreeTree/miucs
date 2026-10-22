import AppKit

/// Explicit, offline rendering fixture. Normal launches always consume system audio.
@MainActor
enum FlightPreview {
    static func verifyWindow(to output: URL) throws {
        let suite = "MiucsWindowTest-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let panel = VisualizerPanel(engine: AudioEngine(), preferences: preferences, persistsFrame: false)
        var checks = [[String: Any]]()
        func record(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        record("400x260 native panel", panel.frame.width == 400 && panel.frame.height == 260)
        record("Transparent window, no shadow", !panel.isOpaque && panel.backgroundColor?.alphaComponent == 0 && !panel.hasShadow)
        record("Default mouse click-through", panel.ignoresMouseEvents && !panel.isAdjustingPosition)
        panel.setDrawingWidth(600)
        record("Scale to 150 percent without stretching", panel.frame.width == 600 && panel.frame.height == 390 && panel.drawingScale == 1.5)
        record("Drawing view follows window size", panel.contentView?.bounds.size == panel.frame.size)
        record("Scaling preserves mouse click-through", panel.ignoresMouseEvents)
        let restored = VisualizerPanel(engine: AudioEngine(), preferences: preferences, persistsFrame: false)
        record("Custom size survives reopening", restored.frame.width == 600 && restored.frame.height == 390)
        panel.setDrawingWidth(100)
        record("Small size has readable lower bound", panel.frame.width == 280 && panel.frame.height == 182)
        panel.setDrawingWidth(100_000)
        record("Large size fits a visible display", panel.frame.width <= 1000 && abs(panel.frame.width / panel.frame.height - 400.0 / 260) < 1e-9 && NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -0.1, dy: -0.1).contains(panel.frame) })
        let validFrame = panel.frame
        panel.setDrawingWidth(.nan)
        record("Nonfinite size is ignored", panel.frame == validFrame)
        panel.setDrawingWidth(400)
        record("Does not take keyboard focus", !panel.canBecomeKey)
        panel.setAdjustingPosition(true)
        record("Position adjustment accepts mouse", !panel.ignoresMouseEvents && panel.isAdjustingPosition)
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setDrawingWidth(480, topLeft: topLeft, persist: false)
        record("Drag resize keeps upper left anchored", panel.frame.minX == topLeft.x && panel.frame.maxY == topLeft.y && !panel.ignoresMouseEvents)
        panel.setAdjustingPosition(false)
        record("Finishing adjustment restores click-through", panel.ignoresMouseEvents && !panel.isAdjustingPosition)
        panel.orderOut(nil)
        record("Hide restores safe input state", !panel.isVisible && panel.ignoresMouseEvents)
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native window: \(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { throw AudioAnalysisError.invalidInput("Window behavior checks failed") }
    }

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var world = SoundFlightWorld(seed: 42)
        let notes = [60.0, 64, 67, 72, 67, 64, 62, 69]
        for tick in 0..<1_080 {
            let t = Double(tick) / 60
            let pulse = tick % 36 == 0
            let audio = AudioFeatures(
                time: t, sampleRate: 48_000, channelCount: 2,
                rms: 0.08, rmsDBFS: -22, peak: 0.2, crestDB: 8,
                envelope: 0.08, isSilent: false, silenceDuration: 0,
                lowEnergy: 0.002 + (pulse ? 0.01 : 0), midEnergy: 0.003, highEnergy: 0.001,
                lowShare: 0.3, midShare: 0.5, highShare: 0.2, centroidHz: 2_000,
                bandwidthHz: 1_500, flatness: 0.15, spectralFlux: pulse ? 0.8 : 0.05,
                onsetThreshold: 0.2, isOnset: pulse, balance: 0, sideEnergyRatio: 0.2,
                correlation: 0.6, displayBands: Array(repeating: 0.5, count: 24)
            )
            world.receive(audio: audio)
            let midi = notes[(tick / 54) % notes.count]
            world.receive(melody: MelodyFrame(time: t, pitchHz: 440 * pow(2, (midi - 69) / 12), confidence: 1, isMelodic: true))
            world.advance(seconds: 1.0 / 60)
        }
        let view = PencilFlightView(preview: world)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 520,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.translateBy(x: 0, y: 260)
        context.cgContext.scaleBy(x: 1, y: -1)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("flight-transparent.png"))
        for (name, color) in [("light", NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)),
                              ("dark", NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.17, alpha: 1))] {
            let image = NSImage(size: NSSize(width: 400, height: 260))
            image.lockFocus()
            color.setFill(); NSRect(x: 0, y: 0, width: 400, height: 260).fill()
            NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 400, height: 260)).draw(in: NSRect(x: 0, y: 0, width: 400, height: 260))
            image.unlockFocus()
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: directory.appendingPathComponent("flight-\(name).png"))
        }
        let metadata: [String: Any] = ["fixture": "synthetic features; same production renderer", "score": world.score,
                                       "width": 400, "height": 260, "gates": world.gates.count]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("preview.json"))
        print("Flight previews: \(directory.path)")
    }
}
