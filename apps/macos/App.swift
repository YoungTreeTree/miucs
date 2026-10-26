import AppKit
import SwiftUI
import Combine

@main
struct MiucsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("可视化") {
                ForEach(appDelegate.visualizationDescriptors, id: \.id) { descriptor in
                    Button(descriptor.name) { appDelegate.selectVisualization(id: descriptor.id) }
                }
            }
            CommandGroup(replacing: .appSettings) {
                VisualizationColorCommand(store: appDelegate.appearanceStore)
            }
        }
    }
}

private struct VisualizationColorCommand: View {
    @ObservedObject var store: VisualizationAppearanceStore
    var body: some View {
        Picker("线条颜色", selection: Binding(get: { store.selection }, set: { store.select($0) })) {
            ForEach(VisualizationInk.allCases) { ink in Text(ink.name).tag(ink) }
        }
        .pickerStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appearanceStore = VisualizationAppearanceStore()
    private var statusItem: NSStatusItem?
    private var panel: VisualizerPanel?
    private let engine = AudioEngine()
    private let keyboardEngine = KeyboardEngine()
    private var keyboardItem: NSMenuItem?
    private var keyboardSubscription: AnyCancellable?
    private var diagnostics: AudioDiagnostics?
    private var moveItem: NSMenuItem?
    private var sizeItem: NSMenuItem?
    private let registry = BuiltInVisualizations.registry()
    var visualizationDescriptors: [VisualizationDescriptor] { registry.descriptors }
    private var visualizationMenu: NSMenu?
    private var colorMenu: VisualizationColorMenu?
    private var appearanceSubscription: AnyCancellable?

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

        if CommandLine.arguments.contains("--render-staff-preview") {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--output"), i + 1 < args.count {
                do { try StaffNotePreview.render(to: URL(fileURLWithPath: args[i + 1])) }
                catch { fputs("Staff preview failed: \(error)\n", stderr) }
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

        if CommandLine.arguments.contains("--diagnose-inputs") {
            Task { await InputDiagnostics.run(audio: engine, keyboard: keyboardEngine, arguments: CommandLine.arguments) }
            return
        }

        appearanceStore.saveSelection()
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
        for (percent, label) in [(10, "极小"), (80, "小"), (100, "标准"), (125, "舒展"), (150, "大"), (200, "特大")] {
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
        let colors = VisualizationColorMenu(store: appearanceStore)
        colorMenu = colors; menu.addItem(colors.item)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "重新连接音频", action: #selector(reconnect), keyEquivalent: "r")
        )
        let keyboard = NSMenuItem(title: "键盘监听：正在连接…", action: #selector(connectKeyboard), keyEquivalent: "")
        keyboard.target = self; keyboardItem = keyboard; menu.addItem(keyboard)
        keyboardSubscription = keyboardEngine.$state.sink { [weak self] state in
            self?.updateKeyboardMenu(state)
        }
        menu.addItem(
            NSMenuItem(title: "退出 Miucs", action: #selector(quit), keyEquivalent: "q")
        )
        item.menu = menu
        statusItem = item

        let panel = VisualizerPanel(source: engine.channel, registry: registry, keyboardSource: keyboardEngine.channel)
        self.panel = panel
        appearanceSubscription = appearanceStore.$selection.sink { [weak self] ink in
            self?.panel?.visualizationHost.applyAppearance(ink.appearance)
        }
        panel.orderFrontRegardless()
        panel.onAdjustmentChange = { [weak self, weak panel] in
            self?.moveItem?.title = panel?.isAdjustingPosition == true
                ? "完成调整（恢复鼠标穿透）" : "调整位置与大小…"
        }
        panel.onSizeChange = { [weak self] in self?.updateSizeMenu() }
        updateSizeMenu()
        updateVisualizationMenu()

        Task { await engine.start() }
        Task {
            let key = "MiucsKeyboardPermissionRequested.v1"
            let request = !UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            await keyboardEngine.start(requestAccess: request)
        }
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
        guard let panel else { return }
        panel.setDrawingWidth(panel.descriptor.layout.width * Double(sender.tag) / 100)
    }

    @objc private func selectVisualization(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectVisualization(id: id)
    }

    func selectVisualization(id: String) {
        guard panel?.selectVisualization(id: id) == true else { return }
        updateVisualizationMenu()
        updateSizeMenu()
    }

    private func updateVisualizationMenu() {
        for option in visualizationMenu?.items ?? [] {
            option.state = option.representedObject as? String == panel?.descriptor.id ? .on : .off
        }
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

    private func updateKeyboardMenu(_ state: KeyboardSourceState) {
        let label: String
        switch state {
        case .running: label = "已连接"
        case .permissionRequired: label = "点击授权…"
        case .secureInput: label = "安全输入期间暂停"
        case .suspended: label = "等待系统恢复"
        case .recovering: label = "正在重连…"
        case .connecting: label = "正在连接…"
        case .stopped: label = "点击连接…"
        }
        keyboardItem?.title = "键盘监听：" + label
    }

    @objc private func connectKeyboard() {
        Task {
            await keyboardEngine.start(requestAccess: true)
            if keyboardEngine.state == .permissionRequired,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func quit() {
        keyboardEngine.stop()
        engine.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardEngine.stop()
        engine.stop()
        panel?.saveDrawingFrame()
        panel?.visualizationHost.dispose()
    }
}
