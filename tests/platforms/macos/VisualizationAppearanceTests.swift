import AppKit
import Combine

@MainActor
private final class InkProbe: VisualizationSession {
    let descriptor = VisualizationDescriptor(id: "ink-probe", name: "Ink probe")
    var applied: VisualizationAppearance?
    var activeInk: VisualizationAppearance?
    func applyAppearance(_ appearance: VisualizationAppearance) { applied = appearance }
    func activate(viewport: VisualizationViewport) { activeInk = applied }
    func resize(to viewport: VisualizationViewport) {}
    func update(input: FeatureInput, deltaTime: Double) {}
    func deactivate() {}
    func dispose() {}
}

@main
@MainActor
enum VisualizationAppearanceTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        let suite = "MiucsAppearanceTest-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        let inks = VisualizationInk.allCases
        check("Exactly five distinct, stable ink choices are shared by all modules", inks.count == 5 && Set(inks.map(\.rawValue)).count == 5 && Set(inks.map(\.color)).count == 5)
        let empty = VisualizationAppearanceStore(preferences: preferences)
        check("Existing installs retain original opacity without writing a new preference", empty.transparency == 0 && preferences.object(forKey: VisualizationAppearanceStore.transparencyKey) == nil)
        empty.setTransparency(50)
        check("Transparency survives relaunch independently of ink", VisualizationAppearanceStore(preferences: preferences).transparency == 50 && empty.selection == .graphite)
        empty.setTransparency(999)
        check("Transparency cannot make the visualization entirely invisible", empty.transparency == 90)
        preferences.set(-20, forKey: VisualizationAppearanceStore.transparencyKey)
        check("Invalid saved transparency is clamped", VisualizationAppearanceStore(preferences: preferences).transparency == 0)
        preferences.set("invalid", forKey: VisualizationAppearanceStore.transparencyKey)
        check("Corrupt transparency falls back to original opacity", VisualizationAppearanceStore(preferences: preferences).transparency == 0)
        preferences.removeObject(forKey: VisualizationAppearanceStore.transparencyKey)
        check("Loading a store for offline tools does not write color preferences", preferences.object(forKey: VisualizationAppearanceStore.preferencesKey) == nil)
        empty.saveSelection()
        check("First launch uses graphite and stores one small identifier", empty.selection == .graphite && preferences.string(forKey: VisualizationAppearanceStore.preferencesKey) == "graphite")
        empty.select(.blue)
        check("The global selection survives a new store", VisualizationAppearanceStore(preferences: preferences).selection == .blue)
        preferences.set("future-unknown-ink", forKey: VisualizationAppearanceStore.preferencesKey)
        check("Unknown saved ink safely falls back to graphite", VisualizationAppearanceStore(preferences: preferences).selection == .graphite)
        preferences.removeObject(forKey: VisualizationAppearanceStore.preferencesKey)
        let forest = PencilPalettePreset.all.first { $0.id == "forest" }!.palette
        let legacyData = try JSONEncoder().encode(forest)
        preferences.set(legacyData, forKey: PencilPaletteStore.preferencesKey)
        let migrated = VisualizationAppearanceStore(preferences: preferences)
        check("Legacy flight ink migrates to the nearest shared color without losing its original data", migrated.selection == .green && preferences.data(forKey: PencilPaletteStore.preferencesKey) == legacyData)
        migrated.select(.violet)
        check("An explicit shared selection takes precedence over a legacy palette", VisualizationAppearanceStore(preferences: preferences).selection == .violet)
        preferences.removeObject(forKey: VisualizationAppearanceStore.preferencesKey)
        preferences.set(Data("corrupt".utf8), forKey: PencilPaletteStore.preferencesKey)
        check("Corrupt legacy data cannot enter the shared color model", VisualizationAppearanceStore(preferences: preferences).selection == .graphite)
        preferences.set(legacyData, forKey: PencilPaletteStore.preferencesKey)

        let store = VisualizationAppearanceStore(preferences: preferences)
        let transparencyMenu = VisualizationTransparencyMenu(store: store)
        var transparencyActionsWork = true
        for (index, percent) in VisualizationAppearanceStore.opacityPresets.enumerated() {
            transparencyMenu.item.submenu!.performActionForItem(at: index)
            transparencyActionsWork = transparencyActionsWork && store.opacity == percent &&
                VisualizationAppearanceStore(preferences: preferences).opacity == percent &&
                transparencyMenu.item.submenu!.items.filter { $0.state == .on }.map(\.tag) == [percent]
        }
        check("Native opacity menu actions apply, mark and save ten levels from 10 to 100 percent", transparencyActionsWork && VisualizationAppearanceStore.opacityPresets == Array(stride(from: 10, through: 100, by: 10)))
        store.setTransparency(0)
        let colorMenu = VisualizationColorMenu(store: store)
        let menu = colorMenu.item.submenu!
        check("The menu exposes only the five named swatches with one selection", menu.items.count == 5 && menu.items.allSatisfy { $0.image != nil } && menu.items.filter { $0.state == .on }.count == 1)
        let windowCount = app.windows.count
        var actionsWork = true
        for (index, ink) in inks.enumerated() {
            menu.performActionForItem(at: index)
            actionsWork = actionsWork && store.selection == ink && menu.items[index].state == .on &&
                menu.items.filter { $0.state == .on }.count == 1 &&
                VisualizationAppearanceStore(preferences: preferences).selection == ink
        }
        check("Actual native menu actions select, mark and persist every color", actionsWork)
        check("Choosing a color opens no configuration window", app.windows.count == windowCount)

        let channel = FeatureChannel(now: { 0 }), generation = UUID()
        channel.reset(sessionID: generation, state: .running)
        let legacyStore = PencilPaletteStore(preferences: preferences)
        let registry = BuiltInVisualizations.registry(preferences: preferences, paletteStore: legacyStore)
        let panel = VisualizerPanel(source: channel, registry: registry, selectedID: "pencil-flight", preferences: preferences, persistsFrame: false)
        let binding = store.$selection.sink { panel.visualizationHost.applyAppearance($0.appearance) }
        let opacityBinding = store.$transparency.sink { panel.visualizationHost.applyTransparency($0) }
        defer { binding.cancel(); opacityBinding.cancel(); panel.orderOut(nil); panel.visualizationHost.dispose() }
        let host = panel.visualizationHost
        var opacitySurvivesSwitch = true
        store.setTransparency(70)
        for id in ["staff-note", "pixel-keyboard", "pencil-flight"] {
            _ = panel.selectVisualization(id: id)
            opacitySurvivesSwitch = opacitySurvivesSwitch && abs(Double(host.activeView!.alphaValue) - 0.3) < 0.001 &&
                host.subviews.filter { $0 !== host.activeView }.allSatisfy { $0.alphaValue == 1 }
        }
        check("All three modes inherit transparency while adjustment overlays remain opaque", opacitySurvivesSwitch && panel.alphaValue == 1)
        host.controller.resume()
        channel.publish(audio: StaffNotePreview.audio(0), melody: StaffNotePreview.melody(0, midi: 60), sessionID: generation)
        host.controller.tick(deltaTime: 1.0 / 60)
        let flight = host.controller.current as! MacPencilFlightSession
        let flightY = flight.simulation.world.birdY, initialFrame = panel.frame
        store.setTransparency(50)
        check("Changing transparency preserves music session, geometry and mouse passthrough", host.controller.current === flight && flight.simulation.world.birdY == flightY && panel.frame == initialFrame && panel.ignoresMouseEvents && host.activeView?.alphaValue == 0.5)
        store.select(.blue)
        check("A single ink reaches every flight part and its status text immediately", PencilPart.allCases.allSatisfy { flight.drawing.palette[$0] == VisualizationInk.blue.color } && flight.hintColor == VisualizationInk.blue.color.nsColor)
        check("Recoloring keeps the same session, pitch, geometry, transparency and click-through", host.controller.current === flight && flight.simulation.world.birdY == flightY && panel.frame == initialFrame && panel.ignoresMouseEvents && !panel.isOpaque)
        var onset = StaffNotePreview.audio(0.02); onset.isOnset = true
        channel.publish(audio: onset, melody: StaffNotePreview.melody(0.02, midi: 66), sessionID: generation)
        store.select(.orange); host.controller.tick(deltaTime: 1.0 / 60)
        check("Changing color does not drain pending onsets or restart audio", flight.simulation.world.flap > 0 && channel.snapshot?.sequence == 2 && channel.snapshot?.sessionID == generation)
        _ = panel.selectVisualization(id: "staff-note")
        let staff = host.controller.current as! MacStaffNoteSession
        check("A newly mounted module gets the shared ink before its first update", staff.drawing.inkStyle == VisualizationInk.orange.appearance && staff.hintColor == VisualizationInk.orange.color.nsColor)
        host.controller.tick(deltaTime: 1.0 / 60)
        let trace = staff.simulation.scene.trace, elapsed = staff.simulation.scene.elapsed
        store.select(.violet)
        check("Staff recoloring changes ink without touching melody or trace history", staff.drawing.inkStyle == VisualizationInk.violet.appearance && staff.simulation.scene.trace == trace && staff.simulation.scene.elapsed == elapsed && !trace.isEmpty)
        legacyStore.useForAll(VisualizationInk.green.color)
        _ = panel.selectVisualization(id: "pencil-flight")
        let returned = host.controller.current as! MacPencilFlightSession
        check("Returning to flight retains the shared selection even if legacy colors changed", PencilPart.allCases.allSatisfy { returned.drawing.palette[$0] == VisualizationInk.violet.color })
        check("Shared coloring uses no per-module palette window", returned.settingsTitle == nil && staff.settingsTitle == nil)
        panel.orderOut(nil); store.select(.green)
        store.setTransparency(20)
        check("Transparency changes while hidden do not restart rendering", !host.controller.isActive && host.activeView?.alphaValue == 0.8)
        check("Changing ink while hidden updates paint without activating rendering", !host.controller.isActive && returned.drawing.palette.bird == VisualizationInk.green.color)

        let probeRegistry = VisualizationRegistry(), probe = InkProbe()
        probeRegistry.register(probe.descriptor) { probe }
        let controller = VisualizationController(source: FeatureChannel(), registry: probeRegistry)
        controller.applyAppearance(VisualizationInk.blue.appearance); controller.resume()
        _ = controller.select(id: "ink-probe")
        check("Future modules receive the shared appearance before activation", probe.activeInk == VisualizationInk.blue.appearance)
        controller.dispose()

        let output = URL(fileURLWithPath: "build/shared-color-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let staffView = StaffNoteView(preview: StaffNotePreview.sampleScene())
        let birdView = PencilFlightView(preview: PencilFlightSampleScene.make())
        var staffPixels = Set<Data>(), birdPixels = Set<Data>()
        var stable = true, visible = true, transparent = true
        let original = bytes(render(staffView, width: 800, height: 160))
        for ink in inks {
            staffView.applyAppearance(ink.appearance); birdView.updatePalette(PencilPalette(ink: ink.color))
            let staffBitmap = render(staffView, width: 800, height: 160)
            let birdBitmap = render(birdView, width: 400, height: 260)
            staffPixels.insert(bytes(staffBitmap)); birdPixels.insert(bytes(birdBitmap))
            stable = stable && bytes(staffBitmap) == bytes(render(staffView, width: 800, height: 160))
            transparent = transparent && staffBitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0 && birdBitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0
            for (name, white) in [("light", 0.96), ("dark", 0.12)] {
                let background = NSColor(calibratedWhite: white, alpha: 1)
                let b = render(staffView, width: 800, height: 160, background: background)
                let center = b.colorAt(x: 1000, y: 148)!.usingColorSpace(.deviceRGB)!
                let paper = background.usingColorSpace(.deviceRGB)!
                let contrast = max(abs(center.redComponent - paper.redComponent), abs(center.greenComponent - paper.greenComponent), abs(center.blueComponent - paper.blueComponent))
                visible = visible && contrast > 0.04
                try b.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("staff-\(ink.rawValue)-\(name).png"))
            }
            try birdBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("flight-\(ink.rawValue).png"))
        }
        check("Both production renderers produce distinct pixels for all five inks", staffPixels.count == 5 && birdPixels.count == 5)
        check("All five staff inks remain visible on light and dark backgrounds", visible)
        check("Color changes retain transparent margins", transparent)
        check("Static pencil marks remain byte-stable in every ink", stable)
        staffView.applyAppearance(.graphite)
        check("Recoloring invalidates cached labels and returns to the exact original pixels", bytes(render(staffView, width: 800, height: 160)) == original)
        let fresh = StaffNoteView(preview: StaffNotePreview.sampleScene())
        staffView.applyAppearance(VisualizationInk.blue.appearance); fresh.applyAppearance(VisualizationInk.blue.appearance)
        check("A recolored retained view matches a fresh renderer including text", bytes(render(staffView, width: 800, height: 160)) == bytes(render(fresh, width: 800, height: 160)))

        var nativeColors = Set<Data>()
        var nativeStable = true
        for ink in inks {
            staffView.applyAppearance(ink.appearance)
            let first = render(staffView, width: 800, height: 160, retainedLayers: true)
            nativeColors.insert(bytes(first))
            nativeStable = nativeStable && bytes(first) == bytes(render(staffView, width: 800, height: 160, retainedLayers: true)) &&
                first.colorAt(x: 0, y: 0)!.alphaComponent == 0
        }
        check("Retained native layers recolor all five inks with stable transparent output", nativeColors.count == 5 && nativeStable)

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/visualization-appearance-tests.json"))
        if failures > 0 { exit(1) }
    }

    static func bytes(_ bitmap: NSBitmapImageRep) -> Data {
        Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    static func render(_ view: NSView, width: Int, height: Int, background: NSColor? = nil,
                       retainedLayers: Bool = false) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let cg = context.cgContext
        cg.translateBy(x: 0, y: Double(height * 2)); cg.scaleBy(x: 2, y: -2)
        if let background { cg.setFillColor(background.cgColor); cg.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        if retainedLayers {
            view.wantsLayer = true
            view.updateLayer()
            view.layer!.render(in: cg)
        } else {
            view.draw(view.bounds)
        }
        return bitmap
    }
}
