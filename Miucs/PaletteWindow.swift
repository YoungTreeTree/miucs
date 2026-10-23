import AppKit
import SwiftUI

@MainActor
final class PaletteWindowController: NSWindowController {
    init(store: PencilPaletteStore, persistsFrame: Bool = true) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 730),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Miucs · 调色盘"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(srgbRed: 0.975, green: 0.969, blue: 0.949, alpha: 1)
        window.minSize = NSSize(width: 820, height: 620)
        window.contentView = NSHostingView(rootView: PaletteEditor(store: store).preferredColorScheme(.light))
        super.init(window: window)
        window.center()
        if persistsFrame { window.setFrameAutosaveName("MiucsPaletteWindow") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum PaletteStyle {
    static let ink = Color(red: 0.22, green: 0.25, blue: 0.22)
    static let secondary = Color(red: 0.46, green: 0.48, blue: 0.43)
    static let accent = Color(red: 0.31, green: 0.41, blue: 0.32)
    static let paper = Color(red: 0.975, green: 0.969, blue: 0.949)
    static let sidebar = Color(red: 0.938, green: 0.938, blue: 0.903)
    static let border = Color(red: 0.86, green: 0.87, blue: 0.82)
}

@MainActor
private struct PaletteEditor: View {
    @ObservedObject var store: PencilPaletteStore
    @State private var selectedPart: PencilPart = .bird
    @State private var background: PreviewPaper = .light
    @State private var hexDraft = ""
    @State private var hexError = false

    private static let swatches = ["3D3C38", "77816A", "48745A", "508D8B", "477B9F", "576BA4", "8C71A6",
                                   "B67F99", "BA6662", "C27D50", "C4A253", "A79176", "C9C5B7", "EAE5D9"]
        .map { PencilColor(hex: $0)! }

    private var currentColor: PencilColor { store.palette[selectedPart] }
    private var pickerColor: Binding<Color> {
        Binding(get: { Color(nsColor: currentColor.nsColor) }, set: { color in
            if let ink = PencilColor(nsColor: NSColor(color)) { store.set(ink, for: selectedPart) }
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 206)
            Rectangle().fill(PaletteStyle.border.opacity(0.65)).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heading
                        preview
                        parts
                        colorEditor
                        quickColors
                    }
                    .padding(24)
                }
                footer
            }
            .background(PaletteStyle.paper)
        }
        .padding(.top, 28)
        .background(PaletteStyle.paper)
        .foregroundStyle(PaletteStyle.ink)
        .tint(PaletteStyle.accent)
        .onAppear { syncHex() }
        .onChange(of: selectedPart) { syncHex() }
        .onChange(of: store.palette) { syncHex() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 24, weight: .light))
                Text("Miucs").font(.system(size: 21, weight: .semibold, design: .rounded))
            }
            .padding(.bottom, 7)
            Text("给音乐一点颜色。")
                .font(.system(size: 11)).foregroundStyle(PaletteStyle.secondary)
            Text("配色灵感").font(.system(size: 11, weight: .medium))
                .foregroundStyle(PaletteStyle.secondary).padding(.top, 32).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(PencilPalettePreset.all) { preset in presetButton(preset) }
                    if store.preset == nil {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                            Text("我的配色")
                            Spacer()
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium)).padding(12)
                        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Spacer(minLength: 18)
            HStack(spacing: 6) {
                ForEach(["56705B", "B2986B", "BF704B", "8B72A2", "467C92"], id: \.self) { hex in
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Color(nsColor: PencilColor(hex: hex)!.nsColor))
                }
            }
            .padding(.bottom, 14).accessibilityHidden(true)
            Button(action: store.reset) {
                Label("恢复原生石墨", systemImage: "arrow.counterclockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(PaletteStyle.secondary)
            .help("恢复默认铅笔颜色，画面立即生效")
        }
        .padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 26)
        .background(PaletteStyle.sidebar)
    }

    private func presetButton(_ preset: PencilPalettePreset) -> some View {
        let selected = store.palette == preset.palette
        return Button { store.apply(preset.palette) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(preset.name).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    Spacer()
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                }
                HStack(spacing: 5) {
                    ForEach(PencilPart.allCases) { part in
                        Capsule().fill(Color(nsColor: preset.palette[part].nsColor)).frame(width: 21, height: 7)
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.78) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? PaletteStyle.border : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).help(preset.subtitle)
        .accessibilityLabel(preset.name + "，" + preset.subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("调色盘").font(.system(size: 28, weight: .semibold))
                Spacer()
                Text(store.name).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(PaletteStyle.sidebar, in: Capsule())
            }
            Text("为每一笔，找到自己的颜色。")
                .font(.system(size: 12)).foregroundStyle(PaletteStyle.secondary)
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(PaletteStyle.accent).frame(width: 5, height: 5)
                    Text("实时预览").font(.system(size: 11, weight: .medium))
                }
                Spacer()
                Picker("预览背景", selection: $background) {
                    ForEach(PreviewPaper.allCases) { paper in Text(paper.rawValue).tag(paper) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 163)
            }
            .padding(.horizontal, 16).padding(.top, 14)
            PencilScenePreview(palette: store.palette)
                .frame(width: 320, height: 208).frame(maxWidth: .infinity).padding(.horizontal, 12)
                .accessibilityLabel("当前配色的小鸟、管道、音符和云朵预览")
            HStack {
                Text("示例画面 · 与桌面同步配色")
                Spacer()
                Image(systemName: "square.on.square").font(.system(size: 9))
                Text("透明悬浮")
            }
            .font(.system(size: 10))
            .foregroundStyle(background == .dark ? Color.white.opacity(0.65) : PaletteStyle.secondary)
            .padding(.horizontal, 16).padding(.bottom, 13)
        }
        .background { PreviewPaperView(paper: background) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PaletteStyle.border.opacity(0.8)))
        .foregroundStyle(background == .dark ? Color.white.opacity(0.85) : PaletteStyle.ink)
    }

    private var parts: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("01", "选择要调色的部分")
            HStack(spacing: 8) {
                ForEach(PencilPart.allCases) { part in
                    let selected = part == selectedPart
                    Button { selectedPart = part } label: {
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: store.palette[part].nsColor)).frame(width: 8, height: 8)
                                Image(systemName: part.symbol).font(.system(size: 15, weight: .regular))
                            }
                            Text(part.name).font(.system(size: 10, weight: selected ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(selected ? PaletteStyle.sidebar : Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? PaletteStyle.accent.opacity(0.65) : PaletteStyle.border.opacity(0.6)))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("调节" + part.name + "颜色，当前 " + store.palette[part].hex)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var colorEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("02", "调一支自己的彩铅")
            HStack(spacing: 12) {
                ColorPicker("自定义颜色", selection: pickerColor, supportsOpacity: false)
                    .labelsHidden().frame(width: 46, height: 34)
                    .help("打开系统调色盘，可使用色轮、滑块或吸管取色")
                    .accessibilityLabel(selectedPart.name + "自定义颜色")
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedPart.name).font(.system(size: 12, weight: .medium))
                    Text("点击色块，自由调色").font(.system(size: 10)).foregroundStyle(PaletteStyle.secondary)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    TextField("#RRGGBB", text: $hexDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain).frame(width: 77)
                        .onSubmit(applyHex).onChange(of: hexDraft) { hexError = false }
                        .accessibilityLabel("十六进制颜色")
                    Button(action: applyHex) { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).help("应用 HEX 颜色").accessibilityLabel("应用 HEX 颜色")
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hexError ? Color.red.opacity(0.7) : PaletteStyle.border))
                Button { store.useForAll(currentColor) } label: {
                    Label("整幅同色", systemImage: "paintbrush.pointed")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 10)
                }
                .buttonStyle(.plain).background(PaletteStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .help("将当前颜色用于所有铅笔笔触")
            }
            if hexError {
                Text("请输入 3 位或 6 位十六进制颜色，例如 #56705B。")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private var quickColors: some View {
        HStack(spacing: 0) {
            ForEach(Self.swatches, id: \.self) { color in
                Button { store.set(color, for: selectedPart) } label: {
                    Circle().fill(Color(nsColor: color.nsColor)).frame(width: 22, height: 22).padding(3)
                        .overlay(Circle().strokeBorder(currentColor.hex == color.hex ? PaletteStyle.accent : .clear, lineWidth: 1.3))
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(color.hex)
                .accessibilityLabel("将" + selectedPart.name + "设为 " + color.hex)
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
            Text("修改即生效 · 已自动保存").font(.system(size: 11))
            Spacer()
            Text("下次打开，依然是你的颜色。")
                .font(.system(size: 10)).foregroundStyle(PaletteStyle.secondary)
        }
        .foregroundStyle(PaletteStyle.accent).padding(.horizontal, 28).padding(.vertical, 17)
        .overlay(alignment: .top) { Rectangle().fill(PaletteStyle.border.opacity(0.65)).frame(height: 1) }
    }

    private func sectionLabel(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, design: .monospaced)).foregroundStyle(PaletteStyle.secondary)
            Text(title).font(.system(size: 12, weight: .medium))
        }
    }
    private func syncHex() { hexDraft = currentColor.hex; hexError = false }
    private func applyHex() {
        guard let color = PencilColor(hex: hexDraft) else { hexError = true; return }
        store.set(color, for: selectedPart)
        syncHex()
    }
}

private enum PreviewPaper: String, CaseIterable, Identifiable {
    case light = "浅纸", dark = "深色", transparent = "透明"
    var id: String { rawValue }
}

private struct PreviewPaperView: View {
    let paper: PreviewPaper
    var body: some View {
        Canvas { context, size in
            let base = paper == .dark ? Color(red: 0.17, green: 0.20, blue: 0.20) : Color(red: 0.994, green: 0.989, blue: 0.971)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            if paper == .transparent {
                let side = 10.0
                for row in 0...Int(size.height / side) {
                    for column in 0...Int(size.width / side) where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: Double(column) * side, y: Double(row) * side, width: side, height: side)),
                                     with: .color(.black.opacity(0.035)))
                    }
                }
            } else if paper == .light {
                for row in 0...Int(size.height / 7) {
                    for column in 0...Int(size.width / 7) {
                        let offset = row.isMultiple(of: 2) ? 0.0 : 3.0
                        context.fill(Path(ellipseIn: CGRect(x: Double(column) * 7 + offset,
                                                           y: Double(row) * 7, width: 0.6, height: 0.6)),
                                     with: .color(PaletteStyle.ink.opacity(0.06)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private struct PencilScenePreview: NSViewRepresentable {
    let palette: PencilPalette
    func makeNSView(context: Context) -> PencilFlightView {
        PencilFlightView(preview: FlightPreview.sampleWorld(), palette: palette)
    }
    func updateNSView(_ view: PencilFlightView, context: Context) { view.updatePalette(palette) }
}
