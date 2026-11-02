import AppKit
import SwiftUI
import Combine

@main
struct MiucsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { appDelegate.showSettings() }.keyboardShortcut(",")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
    let appearanceStore = VisualizationAppearanceStore()
    let settings = MiucsSettingsModel()
    private var settingsWindow: MiucsSettingsWindow?
    private var statusItem: NSStatusItem?
    private var trayIcon: AppTrayIcon?
    private var panel: VisualizerPanel?
    private let engine = AudioEngine()
    private let keyboardEngine = KeyboardEngine()
    private var diagnostics: AudioDiagnostics?
    private var visibilityItem: NSMenuItem?
    private var moveItem: NSMenuItem?
    private let registry = BuiltInVisualizations.registry()
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--diagnose-audio") || CommandLine.arguments.contains("--verify-audio-recovery") {
            let diagnostics = AudioDiagnostics(engine: engine)
            self.diagnostics = diagnostics
            Task {
                if CommandLine.arguments.contains("--verify-audio-recovery") {
                    await diagnostics.runRecovery(arguments: CommandLine.arguments)
                } else { await diagnostics.run(arguments: CommandLine.arguments) }
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-inputs") {
            Task { await InputDiagnostics.run(audio: engine, keyboard: keyboardEngine, arguments: CommandLine.arguments) }
            return
        }
        appearanceStore.saveSelection()
        configureSettings()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        trayIcon = AppTrayIcon(item: item, source: keyboardEngine.channel)
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ selector: Selector, _ key: String) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
            return entry
        }
        _ = add("打开设置…", #selector(showSettings), ",")
        visibilityItem = add("隐藏皮肤", #selector(toggleVisibility), "h")
        moveItem = add("调整位置与大小…", #selector(togglePositioning), "m")
        menu.addItem(.separator())
        _ = add("退出 Miucs", #selector(quit), "q")
        item.menu = menu
        statusItem = item
        PluginHost.shared.start(audio: engine.channel, keyboard: keyboardEngine.channel)
        createPanelIfNeeded()
        refreshSkins()
        showSettings()
        Task { await engine.start() }
        Task {
            let key = "MiucsKeyboardPermissionRequested.v1"
            let request = !UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            await keyboardEngine.start(requestAccess: request)
        }
    }
    private func configureSettings() {
        settings.selectSkin = { [weak self] id in self?.selectSkin(id: id) }
        settings.setVisible = { [weak self] value in self?.setVisible(value) }
        settings.setScale = { [weak self] value in
            guard let self, let panel = self.panel else { return }
            panel.setDrawingWidth(panel.descriptor.layout.width * value / 100)
            self.syncPanelState()
        }
        settings.setOpacity = { [weak self] value in self?.appearanceStore.setOpacity(Int(value.rounded())) }
        settings.togglePosition = { [weak self] in self?.togglePositioning() }
        settings.reconnectAudio = { [weak self] in self?.reconnect() }
        settings.connectKeyboard = { [weak self] in self?.connectKeyboard() }
        settings.rescan = { [weak self] in self?.rescanSkins() }
        settings.reload = { PluginHost.shared.reloadActive() }
        settings.openDirectory = { [weak self] in self?.openSkinDirectory() }
        engine.$status.sink { [weak self] in self?.settings.audioStatus = $0 }.store(in: &subscriptions)
        keyboardEngine.$state.sink { [weak self] in self?.settings.keyboardState = $0 }.store(in: &subscriptions)
        PluginHost.shared.$errors.sink { [weak self] in self?.settings.errors = $0 }.store(in: &subscriptions)
        appearanceStore.$transparency.sink { [weak self] percent in
            self?.panel?.visualizationHost.applyTransparency(percent)
            self?.settings.opacity = Double(100 - percent)
        }.store(in: &subscriptions)
    }
    private func createPanelIfNeeded() {
        guard panel == nil, !registry.descriptors.isEmpty else { return }
        let panel = VisualizerPanel(source: engine.channel, registry: registry, keyboardSource: keyboardEngine.channel,
                                    geometryPersistence: .sharedSkin)
        self.panel = panel
        panel.visualizationHost.applyAppearance(appearanceStore.appearance)
        panel.visualizationHost.applyTransparency(appearanceStore.transparency)
        panel.onAdjustmentChange = { [weak self] in self?.syncPanelState() }
        panel.onSizeChange = { [weak self] in self?.syncPanelState() }
        panel.orderFrontRegardless()
        syncPanelState()
    }
    private func syncPanelState() {
        settings.selectedID = panel?.descriptor.id ?? ""
        settings.isVisible = panel?.isVisible == true
        settings.isAdjusting = panel?.isAdjustingPosition == true
        if let panel {
            settings.scale = panel.drawingScale * 100
            let layout = panel.descriptor.layout
            settings.scaleRange = (layout.minimumWidth / layout.width * 100)...(layout.maximumWidth / layout.width * 100)
        }
        visibilityItem?.title = settings.isVisible ? "隐藏皮肤" : "显示皮肤"
        visibilityItem?.isEnabled = panel != nil
        moveItem?.title = settings.isAdjusting ? "完成调整" : "调整位置与大小…"
        moveItem?.isEnabled = panel != nil
    }
    private func refreshSkins() {
        settings.skins = PluginHost.shared.metadata.compactMap { info in
            guard let id = info["id"] as? String, let name = info["name"] as? String,
                  let directory = info["directory"] as? String else { return nil }
            return SkinItem(id: id, name: name, directory: URL(fileURLWithPath: directory))
        }
        syncPanelState()
    }
    private func selectSkin(id: String) {
        guard registry.descriptor(id: id) != nil else { return }
        createPanelIfNeeded()
        _ = panel?.selectVisualization(id: id)
        syncPanelState()
    }
    private func rescanSkins() {
        PluginHost.shared.register(in: registry, excluding: SkinItem.retiredIDs)
        if let panel, registry.descriptor(id: panel.descriptor.id) == nil {
            if let next = registry.descriptors.first {
                _ = panel.selectVisualization(id: next.id)
            } else {
                panel.orderOut(nil)
                panel.visualizationHost.dispose()
                self.panel = nil
            }
        }
        createPanelIfNeeded()
        refreshSkins()
    }
    private func openSkinDirectory() {
        let url = URL(fileURLWithPath: PluginNative.shared.user)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(url) { settings.errors = ["无法打开皮肤文件夹。"] }
        } catch { settings.errors = ["无法创建皮肤文件夹：\(error.localizedDescription)"] }
    }
    @objc func showSettings() {
        if settingsWindow == nil { settingsWindow = MiucsSettingsWindow(model: settings) }
        syncPanelState()
        settingsWindow?.present()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func menuWillOpen(_ menu: NSMenu) { syncPanelState() }
    @objc private func toggleVisibility() { setVisible(panel?.isVisible != true) }
    private func setVisible(_ value: Bool) {
        if value { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
        syncPanelState()
    }
    @objc private func togglePositioning() {
        guard let panel else { return }
        panel.setAdjustingPosition(!panel.isAdjustingPosition)
        syncPanelState()
    }
    private func reconnect() { Task { await engine.reconnect() } }
    private func connectKeyboard() {
        Task {
            await keyboardEngine.start(requestAccess: true)
            if keyboardEngine.state == .permissionRequired,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        trayIcon?.stop()
        keyboardEngine.stop()
        engine.stop()
        panel?.saveDrawingFrame()
        panel?.visualizationHost.dispose()
        PluginHost.shared.stop()
    }
}
