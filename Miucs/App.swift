import AppKit
import SwiftUI

@main
struct MiucsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: VisualizerPanel?
    private let engine = AudioEngine()
    private var diagnostics: AudioDiagnostics?
    private var moveItem: NSMenuItem?
    private var sizeItem: NSMenuItem?

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

        if CommandLine.arguments.contains("--diagnose-audio") {
            let diagnostics = AudioDiagnostics(engine: engine)
            self.diagnostics = diagnostics
            Task { await diagnostics.run(arguments: CommandLine.arguments) }
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
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "重新连接音频", action: #selector(reconnect), keyEquivalent: "r")
        )
        menu.addItem(
            NSMenuItem(title: "退出 Miucs", action: #selector(quit), keyEquivalent: "q")
        )
        item.menu = menu
        statusItem = item

        let panel = VisualizerPanel(engine: engine)
        panel.orderFrontRegardless()
        self.panel = panel
        panel.onSizeChange = { [weak self] in self?.updateSizeMenu() }
        updateSizeMenu()

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

    private func updateSizeMenu() {
        guard let panel else { return }
        let percent = panel.drawingScale * 100
        sizeItem?.title = "画面大小（\(Int(percent.rounded()))%）"
        for preset in sizeItem?.submenu?.items ?? [] {
            preset.state = abs(percent - Double(preset.tag)) < 0.5 ? .on : .off
        }
    }

    @objc private func reconnect() {
        engine.stop()
        Task { await engine.start() }
    }

    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
}
