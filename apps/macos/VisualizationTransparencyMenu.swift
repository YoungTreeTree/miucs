import AppKit
import Combine

@MainActor
final class VisualizationTransparencyMenu: NSObject {
    let item = NSMenuItem(title: "画面不透明度", action: nil, keyEquivalent: "")
    private let store: VisualizationAppearanceStore
    private var subscription: AnyCancellable?

    init(store: VisualizationAppearanceStore) {
        self.store = store
        super.init()
        let menu = NSMenu(title: "画面不透明度")
        for percent in VisualizationAppearanceStore.opacityPresets {
            let option = NSMenuItem(title: percent == 100 ? "100%（原始效果）" : "\(percent)%",
                                    action: #selector(selectTransparency(_:)), keyEquivalent: "")
            option.tag = percent; option.target = self
            menu.addItem(option)
        }
        item.submenu = menu
        subscription = store.$transparency.sink { [weak self] percent in
            self?.item.title = "画面不透明度（\(100 - percent)%）"
            for option in self?.item.submenu?.items ?? [] {
                option.state = option.tag == 100 - percent ? .on : .off
            }
        }
    }

    @objc private func selectTransparency(_ sender: NSMenuItem) {
        store.setOpacity(sender.tag)
    }
}
