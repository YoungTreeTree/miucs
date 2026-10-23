import AppKit
import SwiftUI

@main
struct MiucsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(appDelegate.visualizationSettingsTitle) { appDelegate.showVisualizationSettings() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!appDelegate.hasVisualizationSettings)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var visualizationSettingsTitle = "调色盘…"
    @Published private(set) var hasVisualizationSettings = true
    private var statusItem: NSStatusItem?
    private var panel: VisualizerPanel?
    private let engine = AudioEngine()
    private var diagnostics: AudioDiagnostics?
    private var moveItem: NSMenuItem?
    private var sizeItem: NSMenuItem?
    private let registry = BuiltInVisualizations.registry()
    private var visualizationMenu: NSMenu?
    private var settingsItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if CommandLine.arguments.contains("--verify-flight-window") {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--output"), i + 1 < args.count {
                do { try FlightPreview.verifyWindow(to: URL(fileURLWithPath: args[i + 1])) }
                catch { fputs("Window verification failed: \(error)\n", stderr) }
            }
            NSApp.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--render-flight-preview") {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--output"), i + 1 < args.count {
                do { try FlightPreview.render(to: URL(fileURLWithPath: args[i + 1])) }
                catch { fputs("Flight preview failed: \(error)\n", stderr) }
            }
            NSApp.terminate(nil)
            return
        }

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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Miucs"
        )
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "显示拾音器", action: #selector(showPanel), keyEquivalent: "s")
        )
        menu.addItem(
            NSMenuItem(title: "隐藏拾音器", action: #selector(hidePanel), keyEquivalent: "h")
        )
        menu.addItem(.separator())
        let move = NSMenuItem(title: "调整位置与大小…", action: #selector(togglePositioning), keyEquivalent: "m")
        menu.addItem(move)
        moveItem = move
        let size = NSMenuItem(title: "画面大小", action: nil, keyEquivalent: "")
        let sizes = NSMenu(title: "画面大小")
        for (percent, label) in [(80, "小"), (100, "标准"), (125, "舒展"), (150, "大"), (200, "特大")] {
            let preset = NSMenuItem(title: "\(label) · \(percent)%", action: #selector(changeSize(_:)), keyEquivalent: "")
            preset.target = self; preset.tag = percent
            sizes.addItem(preset)
        }
        size.submenu = sizes
        menu.addItem(size)
        sizeItem = size
        let visualizations = NSMenu(title: "可视化")
        for descriptor in registry.descriptors {
            let option = NSMenuItem(title: descriptor.name, action: #selector(selectVisualization(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = descriptor.id
            option.state = descriptor.id == BuiltInVisualizations.defaultID ? .on : .off
            visualizations.addItem(option)
        }
        let visualizationItem = NSMenuItem(title: "可视化", action: nil, keyEquivalent: "")
        visualizationItem.submenu = visualizations; menu.addItem(visualizationItem)
        visualizationMenu = visualizations
        let palette = NSMenuItem(title: "调色盘…", action: #selector(showVisualizationSettings), keyEquivalent: "p")
        palette.target = self
        palette.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        menu.addItem(palette)
        settingsItem = palette
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "重新连接音频", action: #selector(reconnect), keyEquivalent: "r")
        )
        menu.addItem(
            NSMenuItem(title: "退出 Miucs", action: #selector(quit), keyEquivalent: "q")
        )
        item.menu = menu
        statusItem = item

        let panel = VisualizerPanel(source: engine.channel, registry: registry, selectedID: BuiltInVisualizations.defaultID)
        panel.orderFrontRegardless()
        self.panel = panel
        panel.onSizeChange = { [weak self] in self?.updateSizeMenu() }
        updateSizeMenu()
        updateSettingsMenu()

        Task { await engine.start() }
    }

    @objc private func showPanel() {
        panel?.orderFrontRegardless()
    }

    @objc private func hidePanel() {
        panel?.orderOut(nil)
        moveItem?.title = "调整位置与大小…"
    }

    @objc private func togglePositioning() {
        guard let panel else { return }
        panel.setAdjustingPosition(!panel.isAdjustingPosition)
        moveItem?.title = panel.isAdjustingPosition ? "完成调整（恢复鼠标穿透）" : "调整位置与大小…"
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        panel?.setDrawingWidth(Double(sender.tag) * 4)
    }

    @objc func showVisualizationSettings() {
        panel?.visualizationHost.presentSettings()
    }

    @objc private func selectVisualization(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, panel?.visualizationHost.select(id: id) == true else { return }
        for option in visualizationMenu?.items ?? [] {
            option.state = option.representedObject as? String == id ? .on : .off
        }
        updateSettingsMenu()
    }

    private func updateSettingsMenu() {
        let title = panel?.visualizationHost.settingsTitle
        hasVisualizationSettings = title != nil
        visualizationSettingsTitle = title ?? "可视化设置…"
        settingsItem?.title = visualizationSettingsTitle
        settingsItem?.isHidden = title == nil
    }

    private func updateSizeMenu() {
        guard let panel else { return }
        let percent = panel.drawingScale * 100
        sizeItem?.title = "画面大小（\(Int(percent.rounded()))%）"
        for preset in sizeItem?.submenu?.items ?? [] {
            preset.state = abs(percent - Double(preset.tag)) < 0.5 ? .on : .off
        }
    }

    @objc private func reconnect() {
        Task { await engine.reconnect() }
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        panel?.saveDrawingFrame()
        panel?.visualizationHost.dispose()
    }
}
