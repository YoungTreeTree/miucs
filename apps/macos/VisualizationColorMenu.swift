import AppKit
import Combine

/// Native menu swatches, shared with the app menu through the same preference store.
@MainActor
final class VisualizationColorMenu: NSObject {
    let item = NSMenuItem(title: "线条颜色", action: nil, keyEquivalent: "")
    private let store: VisualizationAppearanceStore
    private var subscription: AnyCancellable?
    init(store: VisualizationAppearanceStore) {
        self.store = store
        super.init()
        let menu = NSMenu(title: "线条颜色")
        for ink in VisualizationInk.allCases {
            let option = NSMenuItem(title: ink.name, action: #selector(selectInk(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = ink.rawValue
            option.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                ink.color.nsColor.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
            menu.addItem(option)
        }
        item.submenu = menu
        subscription = store.$selection.sink { [weak self] selected in
            self?.item.title = "线条颜色（\(selected.name)）"
            for option in self?.item.submenu?.items ?? [] {
                option.state = option.representedObject as? String == selected.rawValue ? .on : .off
            }
        }
    }
    @objc private func selectInk(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let ink = VisualizationInk(rawValue: raw) else { return }
        store.select(ink)
    }
}
