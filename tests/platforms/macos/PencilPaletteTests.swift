import AppKit
import Combine

/// Exercises the production store, drawing, and SwiftUI window with isolated defaults.
@main
@MainActor
enum PencilPaletteTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/palette-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "MiucsPaletteTest-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed])
            print("\(passed ? "PASS" : "FAIL") \(name)")
        }

        check("HEX accepts shorthand, case, optional hash, and outer whitespace",
              PencilColor(hex: " #aBc ")?.hex == "#AABBCC" && PencilColor(hex: "56705b")?.hex == "#56705B")
        check("HEX rejects incomplete, alpha, non-ASCII, and malformed values",
              ["", "#", "12345", "11223344", "12GG00", "##123", "＋１２３", "12 3456"].allSatisfy { PencilColor(hex: $0) == nil })
        let gray = PencilColor(nsColor: NSColor(calibratedWhite: 0.4, alpha: 0.2))
        check("System grayscale colors convert to opaque sRGB ink", gray != nil && gray?.nsColor.alphaComponent == 1)
        let bounded = PencilColor(red: -.infinity, green: 2, blue: .nan)
        check("Invalid numeric components cannot enter the renderer", bounded.red == 0 && bounded.green == 1 && bounded.blue == 0)

        let store = PencilPaletteStore(preferences: preferences)
        check("First launch preserves graphite", store.palette == .graphite && store.name == "原生石墨")
        let forest = PencilPalettePreset.all.first { $0.id == "forest" }!
        store.apply(forest.palette)
        check("Preset applies and survives a fresh store", PencilPaletteStore(preferences: preferences).palette == forest.palette && store.name == forest.name)
        let before = store.palette
        let red = PencilColor(hex: "C53D32")!
        store.set(red, for: .bird)
        check("Independent color edit preserves all other parts", PencilPart.allCases.allSatisfy { store.palette[$0] == ($0 == .bird ? red : before[$0]) })
        check("Custom colors survive restart and show their own name", PencilPaletteStore(preferences: preferences).palette == store.palette && store.name == "我的配色")

        let liveSession = MacPencilFlightSession(paletteStore: store)
        let liveView = liveSession.drawing
        let panel = VisualizerPanel(source: FeatureChannel(), registry: BuiltInVisualizations.registry(paletteStore: store), selectedID: BuiltInVisualizations.defaultID, preferences: preferences, persistsFrame: false)
        store.set(PencilColor(hex: "318C73")!, for: .gates)
        check("Existing renderer follows palette changes synchronously", liveView.palette == store.palette &&
              liveSession.hintColor == store.palette.notes.nsColor &&
              (panel.visualizationHost.activeView as? PencilFlightView)?.palette == store.palette)
        check("Recoloring keeps desktop transparency and click-through", panel.ignoresMouseEvents && !panel.isOpaque && panel.backgroundColor?.alphaComponent == 0)
        store.useForAll(red)
        check("Single-color mode updates and persists every ink", PencilPart.allCases.allSatisfy { store.palette[$0] == red && PencilPaletteStore(preferences: preferences).palette[$0] == red })
        store.reset()
        check("Reset restores drawing and removes saved override", store.palette == .graphite && liveView.palette == .graphite && preferences.object(forKey: PencilPaletteStore.preferencesKey) == nil)

        preferences.set(Data("not JSON".utf8), forKey: PencilPaletteStore.preferencesKey)
        check("Corrupted preferences safely fall back to graphite", PencilPaletteStore(preferences: preferences).palette == .graphite)
        var corrupt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(forest.palette)) as! [String: Any]
        corrupt["bird"] = ["red": -0.5, "green": 1.2, "blue": 0.4]
        preferences.set(try JSONSerialization.data(withJSONObject: corrupt), forKey: PencilPaletteStore.preferencesKey)
        check("Out-of-range persisted ink is rejected", PencilPaletteStore(preferences: preferences).palette == .graphite)
        store.reset()

        let world = FlightPreview.sampleWorld()
        let renderer = PencilFlightView(preview: world)
        let original = try render(renderer)
        let originalBytes = bytes(original)
        check("Fixture contains notes, pipes, and particles", world.melodyNoteName != nil && !world.gates.isEmpty && !world.particles.isEmpty)
        for part in PencilPart.allCases {
            var palette = PencilPalette.graphite
            palette[part] = red
            renderer.updatePalette(palette)
            let updated = try render(renderer)
            let changed = zip(originalBytes, bytes(updated)).filter { $0 != $1 }.count
            check("Actual \(part.rawValue) pixels change after editing", changed > 12)
            renderer.updatePalette(.graphite)
        }
        check("Reset invalidates cached text colors and restores exact pixels", bytes(try render(renderer)) == originalBytes)
        let transparentPixels = stride(from: 3, to: originalBytes.count, by: 4).filter { originalBytes[$0] == 0 }.count
        check("Palette leaves the desktop background transparent", Double(transparentPixels) / Double(800 * 520) > 0.85)

        // Standalone previews are drawn offscreen; no desktop or user audio is captured.
        for preset in PencilPalettePreset.all {
            renderer.updatePalette(preset.palette)
            let bitmap = try render(renderer)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(preset.id + ".png"))
        }
        store.apply(forest.palette)
        let controller = PaletteWindowController(store: store, persistsFrame: false)
        let window = controller.window!
        check("Palette is a separate keyboard-accessible window", window.canBecomeKey && window.isReleasedWhenClosed == false)
        let desktopFrame = panel.frame
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        if let content = window.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("palette-window.png"))
            check("Native palette UI renders offscreen", bitmap.pixelsWide >= 820 && bitmap.pixelsHigh >= 600)
        } else { check("Native palette UI renders offscreen", false) }
        window.close()
        store.set(red, for: .bird)
        check("Closing the palette preserves edits and desktop geometry", PencilPaletteStore(preferences: preferences).palette.bird == red && panel.frame == desktopFrame && panel.ignoresMouseEvents)
        panel.orderOut(nil)

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("checks.json"))
        print("Palette: \(checks.count - failures)/\(checks.count) checks passed; \(output.path)")
        if failures > 0 { throw AudioAnalysisError.invalidInput("Pencil palette checks failed") }
    }

    static func bytes(_ bitmap: NSBitmapImageRep) -> [UInt8] {
        Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    static func render(_ view: PencilFlightView) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 520,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AudioAnalysisError.invalidInput("Cannot create palette test bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.translateBy(x: 0, y: 260)
        context.cgContext.scaleBy(x: 1, y: -1)
        view.draw(view.bounds)
        return bitmap
    }
}
