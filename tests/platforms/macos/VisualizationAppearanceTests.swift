import AppKit
import Combine

@MainActor
private final class InkProbe: MacVisualizationSession {
    let descriptor: VisualizationDescriptor
    let view = NSView()
    var settingsTitle: String? { nil }
    init(id: String = "ink-probe") { descriptor = VisualizationDescriptor(id: id, name: id) }
    func presentSettings() {}
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
        let registry = VisualizationRegistry()
        for id in ["pixel-keyboard", "muffin-puppies", "niulai-keyboard", "heiji-kazuha", "zelda-guardian", "yuru-camp", "inuyasha"] {
            registry.register(VisualizationDescriptor(id: id, name: id)) { InkProbe(id: id) }
        }
        let panel = VisualizerPanel(source: channel, registry: registry, selectedID: "pixel-keyboard", preferences: preferences, persistsFrame: false)
        let binding = store.$selection.sink { panel.visualizationHost.applyAppearance($0.appearance) }
        let opacityBinding = store.$transparency.sink { panel.visualizationHost.applyTransparency($0) }
        defer { binding.cancel(); opacityBinding.cancel(); panel.orderOut(nil); panel.visualizationHost.dispose() }
        let host = panel.visualizationHost
        var opacitySurvivesSwitch = true
        store.setTransparency(70)
        for id in ["muffin-puppies", "niulai-keyboard", "heiji-kazuha", "zelda-guardian", "yuru-camp", "inuyasha", "pixel-keyboard"] {
            _ = panel.selectVisualization(id: id)
            opacitySurvivesSwitch = opacitySurvivesSwitch && abs(Double(host.activeView!.alphaValue) - 0.3) < 0.001 &&
                host.subviews.filter { $0 !== host.activeView }.allSatisfy { $0.alphaValue == 1 }
        }
        check("All seven modes inherit transparency while adjustment overlays remain opaque", opacitySurvivesSwitch && panel.alphaValue == 1)
        host.controller.resume()
        let session = host.controller.current as! InkProbe, initialFrame = panel.frame
        store.setTransparency(50)
        store.select(.blue)
        check("Appearance updates preserve session, geometry and click-through", host.controller.current === session && panel.frame == initialFrame && panel.ignoresMouseEvents && host.activeView?.alphaValue == 0.5 && session.applied == VisualizationInk.blue.appearance)
        _ = panel.selectVisualization(id: "muffin-puppies")
        let next = host.controller.current as! InkProbe
        check("Switching applies the shared ink before activation", next.activeInk == VisualizationInk.blue.appearance)
        panel.orderOut(nil); store.select(.green); store.setTransparency(20)
        check("Hidden appearance updates do not restart rendering", !host.controller.isActive && next.applied == VisualizationInk.green.appearance && host.activeView?.alphaValue == 0.8)

        let probeRegistry = VisualizationRegistry(), probe = InkProbe()
        probeRegistry.register(probe.descriptor) { probe }
        let controller = VisualizationController(source: FeatureChannel(), registry: probeRegistry)
        controller.applyAppearance(VisualizationInk.blue.appearance); controller.resume()
        _ = controller.select(id: "ink-probe")
        check("Future modules receive the shared appearance before activation", probe.activeInk == VisualizationInk.blue.appearance)
        controller.dispose()

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/visualization-appearance-tests.json"))
        if failures > 0 { exit(1) }
    }

}
