import AppKit

@MainActor
private final class SkinGeometryProbe: MacVisualizationSession {
    let descriptor: VisualizationDescriptor
    let view = NSView()
    var settingsTitle: String? { nil }
    init(_ descriptor: VisualizationDescriptor) { self.descriptor = descriptor }
    func activate(viewport: VisualizationViewport) {}
    func resize(to viewport: VisualizationViewport) {}
    func update(input: FeatureInput, deltaTime: Double) {}
    func deactivate() {}
    func dispose() {}
    func presentSettings() {}
}

@main
@MainActor
enum SettingsTests {
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = root.appendingPathComponent("build/settings-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("miucs-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let suite = "MiucsSettingsTests-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var failures = [String]()
        func check(_ name: String, _ value: Bool) {
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures.append(name) }
        }

        let registry = PluginVisualizations.registry(userDirectory: temp.path)
        check("Only the supported plugin skin is registered, including an upgraded bundle containing retired demos",
              registry.descriptors.map(\.id) == ["pixel-keyboard"])
        check("Plugin runtime is available without launch flags", PluginNative.shared.available)
        let audio = FeatureChannel(), keyboard = KeyboardChannel()
        PluginHost.shared.start(audio: audio, keyboard: keyboard)
        defer { PluginHost.shared.stop() }
        prefs.set("staff-note", forKey: VisualizerPanel.selectionPreferencesKey)
        let panel = VisualizerPanel(source: audio, registry: registry, preferences: prefs, persistsFrame: false,
                                    keyboardSource: keyboard, monitorsHover: false, geometryPersistence: .sharedSkin)
        defer { panel.visualizationHost.dispose() }
        check("An obsolete selected skin migrates to pixel keyboard and saves the new selection",
              panel.descriptor.id == "pixel-keyboard" && prefs.string(forKey: VisualizerPanel.selectionPreferencesKey) == "pixel-keyboard")
        check("The selected skin uses the Lua plugin session", panel.visualizationHost.controller.current is PluginSession)
        let before = panel.frame
        check("Retired skins cannot be activated", !panel.selectVisualization(id: "pencil-flight") && !panel.selectVisualization(id: "staff-note") && panel.frame == before)
        let appearance = VisualizationAppearanceStore(preferences: prefs)
        appearance.setOpacity(60)
        panel.visualizationHost.applyTransparency(appearance.transparency)
        check("Opacity is applied to the plugin canvas and survives reopening preferences",
              abs((panel.visualizationHost.activeView?.alphaValue ?? 0) - 0.6) < 0.001 && VisualizationAppearanceStore(preferences: prefs).opacity == 60)
        panel.setDrawingWidth(400)
        check("Scale uses skin layout and saves the shared desktop frame", panel.drawingScale == 0.5 && prefs.dictionary(forKey: VisualizerPanel.sharedFramePreferencesKey)?["width"] as? Double == 400)
        try await verifySharedGeometry(check)

        let skinRoot = URL(fileURLWithPath: PluginNative.shared.builtin).appendingPathComponent("pixel-keyboard")
        let skin = SkinItem(id: "pixel-keyboard", name: "像素音乐键盘", directory: skinRoot)
        check("Bundled skin has a decodable image preview", skin.previewURL != nil)
        let outside = temp.appendingPathComponent("preview.png")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: skin.previewURL!)
        check("A preview symlink cannot escape its skin directory", SkinItem(id: "test", name: "test", directory: temp).previewURL == nil)
        try FileManager.default.removeItem(at: outside)
        try FileManager.default.copyItem(at: skin.previewURL!, to: outside)
        check("A third-party skin can supply its own preview image", SkinItem(id: "test", name: "test", directory: temp).previewURL != nil)

        let model = MiucsSettingsModel()
        model.skins = [skin]
        model.selectedID = skin.id
        model.isVisible = true
        model.audioStatus = "系统音频已连接"
        model.keyboardState = .running
        let controller = MiucsSettingsWindow(model: model)
        let window = controller.window!
        let view = window.contentView!
        check("Configuration is a regular, key-capable window independent from the desktop panel", window.canBecomeKey && !panel.canBecomeKey)
        check("Skin, appearance, input, hardware and about settings are available", SettingsPage.allCases.map(\.rawValue) == ["皮肤", "外观与位置", "声音与键盘", "硬件屏幕", "关于 Miucs"])
        for (page, name) in [(SettingsPage.skins, "skins"), (.appearance, "appearance"), (.inputs, "inputs"), (.hardware, "hardware")] {
            model.page = page
            await Task.yield()
            try await Task.sleep(for: .milliseconds(180))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Could not render settings") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        model.keyboardState = .permissionRequired
        check("Input permission state has an actionable explanation", model.keyboardStatus == "需要输入监控权限")
        window.close()
        check("Closing configuration does not dispose the active skin", panel.visualizationHost.controller.current is PluginSession)
        if !failures.isEmpty { fatalError(failures.joined(separator: "; ")) }
        print("Settings integration checks passed")
    }

    static func verifySharedGeometry(_ check: (String, Bool) -> Void) async throws {
        let suite = "MiucsSkinGeometryTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let registry = VisualizationRegistry()
        for id in ["skin-a", "skin-b", "skin-square"] {
            let layout = VisualizationLayout(width: 800, height: id == "skin-square" ? 800 : 460,
                                             minimumWidth: 80, maximumWidth: 1600)
            let descriptor = VisualizationDescriptor(id: id, name: id, layout: layout)
            registry.register(descriptor) { SkinGeometryProbe(descriptor) }
        }
        let screen = NSScreen.main!.visibleFrame
        let starting = NSRect(x: screen.minX + 40, y: screen.minY + 45, width: 261, height: 151)
        preferences.set(["x": starting.minX, "y": starting.minY, "width": starting.width, "height": starting.height],
                        forKey: VisualizerPanel.framePreferencesKey(for: "skin-a"))
        preferences.set(["x": screen.minX + 180, "y": screen.minY + 180, "width": 203.0, "height": 117.0],
                        forKey: VisualizerPanel.framePreferencesKey(for: "skin-b"))
        preferences.set("skin-a", forKey: VisualizerPanel.selectionPreferencesKey)
        func makePanel() -> VisualizerPanel {
            VisualizerPanel(source: FeatureChannel(), registry: registry, preferences: preferences,
                            persistsFrame: false, monitorsHover: false, geometryPersistence: .sharedSkin)
        }
        let panel = makePanel()
        defer { panel.orderOut(nil); panel.visualizationHost.dispose() }
        check("First upgrade keeps the selected skin's saved rectangle, including rounded height", panel.frame == starting)
        let savedB = preferences.dictionary(forKey: VisualizerPanel.framePreferencesKey(for: "skin-b"))!
        _ = panel.selectVisualization(id: "skin-b")
        check("Switching ignores the next skin's old position and size", panel.frame == starting)
        var stable = true
        for _ in 0..<50 {
            for id in ["skin-square", "skin-a", "skin-b"] {
                stable = panel.selectVisualization(id: id) && stable && panel.frame == starting
            }
        }
        check("150 switches never move or resize the canvas, including different skin aspect ratios", stable)
        check("Switching does not overwrite legacy per-skin geometry", NSDictionary(dictionary: savedB).isEqual(to: preferences.dictionary(forKey: VisualizerPanel.framePreferencesKey(for: "skin-b"))!))
        _ = panel.selectVisualization(id: "skin-square")
        let reopened = makePanel()
        check("Restart restores the shared frame without fitting it to the selected skin's aspect ratio", reopened.frame == starting && reopened.descriptor.id == "skin-square")
        reopened.visualizationHost.dispose()
        panel.setDrawingWidth(280)
        panel.setFrameOrigin(NSPoint(x: screen.minX + 70, y: screen.minY + 65))
        panel.saveDrawingFrame()
        let adjusted = panel.frame
        _ = panel.selectVisualization(id: "skin-a")
        check("A user-adjusted size and position carry over to the next skin", panel.frame == adjusted)
        panel.orderOut(nil)
        _ = panel.selectVisualization(id: "skin-b")
        try await Task.sleep(for: .milliseconds(50))
        check("Hidden skin switching keeps geometry and leaves rendering paused", panel.frame == adjusted && !panel.isVisible && !panel.visualizationHost.controller.isActive)
        let final = makePanel()
        check("The last shared position and size survive another restart", final.frame == adjusted)
        final.visualizationHost.dispose()
    }
}
