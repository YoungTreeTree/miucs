import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case skins = "皮肤", appearance = "外观与位置", inputs = "声音与键盘", about = "关于 Miucs"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .skins: "square.grid.2x2"
        case .appearance: "slider.horizontal.3"
        case .inputs: "waveform"
        case .about: "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .skins: "点击卡片，使用你喜欢的皮肤。"
        case .appearance: "调整皮肤的大小、透明度和摆放位置。"
        case .inputs: "连接声音与按键，让皮肤动起来。"
        case .about: "让音乐自己飞。"
        }
    }
}

@MainActor
final class MiucsSettingsModel: ObservableObject {
    @Published var page = SettingsPage.skins
    @Published var skins = [SkinItem]()
    @Published var selectedID = ""
    @Published var isVisible = false
    @Published var scale = 100.0
    @Published var scaleRange = 10.0...200.0
    @Published var opacity = 100.0
    @Published var isAdjusting = false
    @Published var audioStatus = "正在连接系统音频…"
    @Published var keyboardState = KeyboardSourceState.connecting
    @Published var errors = [String]()
    var selectSkin: (String) -> Void = { _ in }
    var setVisible: (Bool) -> Void = { _ in }
    var setScale: (Double) -> Void = { _ in }
    var setOpacity: (Double) -> Void = { _ in }
    var togglePosition: () -> Void = {}
    var reconnectAudio: () -> Void = {}
    var connectKeyboard: () -> Void = {}
    var rescan: () -> Void = {}
    var reload: () -> Void = {}
    var openDirectory: () -> Void = {}
    var currentSkin: SkinItem? { skins.first { $0.id == selectedID } }
    var keyboardStatus: String {
        switch keyboardState {
        case .running: "已连接"
        case .permissionRequired: "需要输入监控权限"
        case .secureInput: "安全输入期间暂停"
        case .suspended: "等待系统恢复"
        case .recovering: "正在重新连接…"
        case .connecting: "正在连接…"
        case .stopped: "未连接"
        }
    }
}

@MainActor
final class MiucsSettingsWindow: NSWindowController {
    init(model: MiucsSettingsModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Miucs 设置"
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = SettingsHostingView(rootView: MiucsSettingsView(model: model))
        window.setFrameAutosaveName("MiucsSettings")
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    // A click on a visible control also works when another application is active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MiucsSettingsView: View {
    @ObservedObject var model: MiucsSettingsModel
    private let accent = Color(red: 0.35, green: 0.44, blue: 0.64)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.page.rawValue).font(.system(size: 24, weight: .semibold))
                        Text(model.page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.page == .skins || model.page == .appearance {
                        Toggle("显示皮肤", isOn: Binding(get: { model.isVisible }, set: { model.setVisible($0) }))
                            .toggleStyle(.switch).controlSize(.small).fixedSize()
                            .disabled(model.currentSkin == nil)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch model.page {
                        case .skins: skins
                        case .appearance: appearance
                        case .inputs: inputs
                        case .about: about
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10))
                    Text(model.page == .skins ? "选择皮肤即时生效" : "更改即时生效，自动保存")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .frame(minWidth: 760, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Miucs").font(.system(size: 19, weight: .semibold))
                    Text("让音乐自己飞。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 8)
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases.filter { $0 != .about }) { page in navigation(page) }
            }
            Spacer()
            navigation(.about)
            Label("在后台运行", systemImage: "circle.fill")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12)
        }
        .padding(.horizontal, 12).padding(.vertical, 28).frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func navigation(_ page: SettingsPage) -> some View {
        Button { model.page = page } label: {
            Label(page.rawValue, systemImage: page.symbol)
                .font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .foregroundStyle(model.page == page ? accent : .secondary)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(SettingsSelectionButtonStyle(kind: .navigation, selected: model.page == page, accent: accent))
    }

    private var skins: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Button("打开皮肤文件夹…", action: model.openDirectory)
                Button("重新扫描", action: model.rescan)
                Spacer()
                Menu {
                    Button("重新加载当前皮肤", action: model.reload).disabled(model.currentSkin == nil)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("皮肤操作")
            }.controlSize(.small)
            if model.skins.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.dashed").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("还没有可用的皮肤").font(.headline)
                    Text("将皮肤文件夹放入皮肤目录，再点击「重新扫描」。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(model.skins) { skin in
                        Button { model.selectSkin(skin.id) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack(alignment: .topTrailing) {
                                    SkinPreview(url: skin.previewURL)
                                        .frame(height: 155).frame(maxWidth: .infinity)
                                        .allowsHitTesting(false)
                                    if model.selectedID == skin.id {
                                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                                            .foregroundStyle(accent).background(.background, in: Circle()).padding(8)
                                            .allowsHitTesting(false)
                                    }
                                }
                                Text(skin.name).font(.system(size: 13, weight: .medium))
                                    .lineLimit(2).padding(.horizontal, 6).padding(.vertical, 12)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(SettingsSelectionButtonStyle(kind: .card, selected: model.selectedID == skin.id, accent: accent))
                            .accessibilityLabel(skin.name)
                            .accessibilityValue(model.selectedID == skin.id ? "当前皮肤" : "未选择")
                    }
                }
            }
            if !model.errors.isEmpty {
                DisclosureGroup("皮肤加载遇到问题") {
                    Text(model.errors.joined(separator: "\n")).font(.system(size: 12))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.foregroundStyle(.orange)
            }
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let skin = model.currentSkin {
                HStack(spacing: 12) {
                    SkinPreview(url: skin.previewURL).frame(width: 76, height: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skin.name).font(.headline)
                        Text("当前皮肤").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                settingsGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("画面大小"); Spacer(); Text("\(Int(model.scale.rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: Binding(get: { model.scale }, set: { model.setScale($0) }), in: model.scaleRange)
                        Text("切换皮肤时保持当前位置与大小").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("不透明度"); Spacer(); Text("\(Int(model.opacity))%").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: Binding(get: { model.opacity }, set: { model.setOpacity($0) }), in: 10...100, step: 10)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("位置与大小")
                            Text(model.isAdjusting ? "完成后恢复鼠标穿透" : "拖动移动，拖动右下角缩放")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.isAdjusting ? "完成调整" : "在桌面上调整…", action: model.togglePosition)
                    }
                }
            } else {
                Text("先在「皮肤」中选择一个皮肤。").foregroundStyle(.secondary)
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup {
                HStack {
                    Label("系统音频", systemImage: "speaker.wave.2")
                    Spacer()
                    Button("重新连接", action: model.reconnectAudio)
                }
                Text(model.audioStatus).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            settingsGroup {
                HStack {
                    Label("键盘响应", systemImage: "keyboard")
                    Spacer()
                    Button(model.keyboardState == .permissionRequired ? "前往系统设置…" : "检查连接", action: model.connectKeyboard)
                }
                Text(model.keyboardStatus).font(.system(size: 12))
                    .foregroundStyle(model.keyboardState == .permissionRequired ? Color.orange : .secondary)
                if model.keyboardState == .permissionRequired {
                    Text("允许 Miucs 使用「输入监控」后，按键才能驱动皮肤。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Label("音频和按键只在本机处理，不保存真实音频、屏幕画面或输入文字。", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var about: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 84, height: 84)
            Text("Miucs").font(.system(size: 28, weight: .semibold))
            Text("让音乐自己飞。").foregroundStyle(.secondary)
            Text("用声音与按键，让桌面上的皮肤动起来。").font(.system(size: 13))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 35)
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

private struct SettingsSelectionButtonStyle: ButtonStyle {
    enum Kind { case navigation, card }
    let kind: Kind
    let selected: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        SettingsSelectionSurface(label: configuration.label, kind: kind, selected: selected,
                                 pressed: configuration.isPressed, accent: accent)
    }
}

private struct SettingsSelectionSurface<Label: View>: View {
    let label: Label
    let kind: SettingsSelectionButtonStyle.Kind
    let selected: Bool
    let pressed: Bool
    let accent: Color
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: kind == .card ? 10 : 7) }
    private var background: Color {
        if kind == .card { return Color(nsColor: .controlBackgroundColor) }
        return selected ? accent.opacity(0.14) : .clear
    }
    private var border: Color {
        if kind == .card && selected { return accent }
        if hovered || pressed { return accent.opacity(0.55) }
        return kind == .card ? Color.primary.opacity(0.12) : .clear
    }

    var body: some View {
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: shape)
            .overlay {
                shape.fill(accent.opacity(pressed ? 0.16 : hovered ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(border, lineWidth: kind == .card && selected ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Displays package artwork without activating a second plugin or input subscription.
private struct SkinPreview: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> NSImageView {
        let view = SkinPreviewImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.url != url || view.image == nil else { return }
        context.coordinator.url = url
        view.image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "暂无预览图片")
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var url: URL? }
}

private final class SkinPreviewImageView: NSImageView {
    // Let the enclosing SwiftUI button own the complete card, including GIF/image pixels.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
