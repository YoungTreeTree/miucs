import AppKit
import QuartzCore

/// Static hardware and pixel tail paths are cached; no per-frame path rebuilding.
@MainActor
final class PixelKeyboardView: NSView {
    private let tail = CAShapeLayer()
    private static let tailPaths: [CGPath] = (0..<PixelTailSprite.frameCount).map { index in
        let path = CGMutablePath()
        for (x,y) in PixelTailSprite.pixels(index: index) { path.addRect(CGRect(x: x, y: y, width: 2, height: 2)) }
        return path
    }
    private let hardware = CALayer()
    private let portrait = CALayer()
    private let canvas = CALayer()
    private var keyLayers = [StaffKeyboardKey: CALayer]()
    private let leftPaw = CALayer(), rightPaw = CALayer(), status = CATextLayer()
    private(set) var keyboard = PixelKeyboardScene(codes: MacStaffKeyboardLayout.keys)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private static let outline = NSColor(hex: 0x393044)
    private static let dark = NSColor(hex: 0x62576F)
    private static let side = NSColor(hex: 0x9A8FA8)
    private static let paper = NSColor(hex: 0xFBF7EF)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.isOpaque = false
        canvas.anchorPoint = .zero; canvas.bounds = CGRect(x: 0, y: 0, width: 800, height: 460)
        layer?.addSublayer(canvas)
        hardware.frame = canvas.bounds; hardware.contents = Self.bitmap(width: 800, height: 460) { Self.drawHardware() }
        hardware.magnificationFilter = .nearest; canvas.addSublayer(hardware)
        for key in PixelKeyboardScene.keys {
            let overlay = CALayer()
            overlay.frame = CGRect(x: key.x, y: key.y, width: key.width, height: 34)
            overlay.contents = Self.bitmap(width: key.width, height: 34) {
                Self.drawKey(label: key.label, x: 0, y: 0, width: key.width, active: true)
            }
            overlay.magnificationFilter = .nearest; overlay.isHidden = true
            canvas.addSublayer(overlay); keyLayers[key.id] = overlay
        }
        let pawImage = Self.bitmap(width: 48, height: 68) { Self.drawPaw() }
        for paw in [leftPaw, rightPaw] {
            paw.contents = pawImage; paw.magnificationFilter = .nearest; paw.minificationFilter = .nearest
            paw.bounds = CGRect(x: 0, y: 0, width: 48, height: 68); paw.anchorPoint = CGPoint(x: 0.5, y: 0)
            canvas.addSublayer(paw)
        }
        status.fontSize = 11; status.alignmentMode = .center; status.foregroundColor = Self.dark.cgColor
        status.frame = CGRect(x: 60, y: 442, width: 680, height: 16); status.contentsScale = 2
        canvas.addSublayer(status)
        portrait.name = "pixel-cat-portrait"
        portrait.frame = CGRect(x: 44, y: 54, width: 64, height: 64)
        portrait.contents = PixelCatPortrait.image
        portrait.contentsGravity = .resizeAspect
        portrait.magnificationFilter = .nearest; portrait.minificationFilter = .nearest
        canvas.addSublayer(portrait)
        tail.name = "pixel-cat-tail"
        tail.frame = CGRect(x: 652, y: 40, width: 96, height: 88)
        tail.fillColor = NSColor.black.cgColor; tail.strokeColor = nil
        tail.path = Self.tailPaths[0]; canvas.addSublayer(tail)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Miucs · 像素音乐键盘")
        present(keyboard)
        resizeContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); resizeContents() }
    private func resizeContents() {
        let scale = min(bounds.width / 800, bounds.height / 460)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        canvas.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }
    func applyAppearance(_ value: VisualizationAppearance) {
        status.foregroundColor = value.ink.nsColor.cgColor
    }
    func presentTail(_ scene: PixelTailScene) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tail.path = Self.tailPaths[scene.spriteIndex]
        CATransaction.commit()
    }
    func present(_ scene: PixelKeyboardScene) {
        keyboard = scene
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (key, overlay) in keyLayers { overlay.isHidden = !scene.isLit(key) }
        for (paw, state, angle) in [(leftPaw, scene.left, -0.12), (rightPaw, scene.right, 0.12)] {
            paw.position = CGPoint(x: state.x, y: state.y - (1 - state.down) * 8)
            paw.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: 1, y: 1 - state.down * 0.06))
        }
        switch scene.state {
        case .running: status.string = ""
        case .permissionRequired: status.string = "允许输入监控后，猫爪会跟随按键"
        case .secureInput: status.string = "安全输入中 · 猫爪暂停"
        case .stopped: status.string = "从菜单开启键盘监听，试试敲几个键"
        default: status.string = "键盘连接中…"
        }
        CATransaction.commit()
    }
    static func bitmap(width: Double, height: Double, draw: () -> Void) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.translateBy(x: 0, y: height * 2); cg.scaleBy(x: 2, y: -2)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        cg.setShouldAntialias(false); draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
    private static func fill(_ points: [(Double, Double)], _ color: NSColor) {
        let p = NSBezierPath()
        for (i, v) in points.enumerated() {
            if i == 0 { p.move(to: NSPoint(x: v.0, y: v.1)) } else { p.line(to: NSPoint(x: v.0, y: v.1)) }
        }
        p.close(); color.setFill(); p.fill()
    }
    private static func pixelBox(_ rect: CGRect, _ color: NSColor, step: Double = 4) {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height, s = step
        fill([(x+s,y),(x+w-s,y),(x+w-s,y+s),(x+w,y+s),(x+w,y+h-s),
              (x+w-s,y+h-s),(x+w-s,y+h),(x+s,y+h),(x+s,y+h-s),(x,y+h-s),(x,y+s),(x+s,y+s)], color)
    }
    private static func drawHardware() {
        // Twin hinges connect the wide screen to the keyboard.
        for x in [100.0, 660] {
            pixelBox(CGRect(x: x, y: 164, width: 40, height: 28), outline)
            pixelBox(CGRect(x: x+5, y: 166, width: 30, height: 22), side, step: 2)
        }
        pixelBox(CGRect(x: 24, y: 0, width: 752, height: 172), outline, step: 8)
        pixelBox(CGRect(x: 28, y: 4, width: 744, height: 164), side, step: 6)
        pixelBox(CGRect(x: 34, y: 10, width: 732, height: 152), dark, step: 4)
        paper.setFill(); CGRect(x: 40, y: 14, width: 720, height: 144).fill()
        fill([(28,184),(772,184),(800,402),(790,418),(10,418),(0,402)], outline)
        fill([(32,188),(768,188),(792,400),(784,412),(16,412),(8,400)], dark)
        fill([(34,188),(766,188),(786,398),(14,398)], side)
        NSColor(hex: 0xBFB5CA).setFill(); CGRect(x: 38, y: 188, width: 724, height: 3).fill()
        for key in PixelKeyboardScene.keys { drawKey(label: key.label, x: key.x, y: key.y, width: key.width, active: false) }
    }
    private static func drawKey(label: String, x: Double, y: Double, width: Double, active: Bool) {
        pixelBox(CGRect(x: x, y: y, width: width, height: 34), outline, step: 3)
        pixelBox(CGRect(x: x+2, y: y+2, width: width-4, height: 30), active ? NSColor(hex: 0xB85863) : NSColor(hex: 0xA49AAF), step: 2)
        let offset = active ? 5.0 : 1.0
        pixelBox(CGRect(x: x+3, y: y+offset, width: width-6, height: 26), active ? NSColor(hex: 0xEF958C) : (label.count > 1 ? NSColor(hex: 0xDBD3E4) : paper), step: 2)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: label.count > 3 ? 10 : 12, weight: .semibold), .foregroundColor: outline]
        let text = NSAttributedString(string: label, attributes: attributes)
        text.draw(at: NSPoint(x: x+(width-text.size().width)/2, y: y+offset+4))
    }
    private static func drawPaw() {
        let palette = [NSColor.clear, NSColor(hex: 0x272330), NSColor(hex: 0xFFF9EE),
                       NSColor(hex: 0xDCD6D9), NSColor(hex: 0x30303D), NSColor(hex: 0x484657)]
        for (y, row) in PixelPawSprite.rows.enumerated() {
            for (x, char) in row.enumerated() {
                guard let n = char.wholeNumberValue, n > 0 else { continue }
                palette[n].setFill(); CGRect(x: Double(x*2+2), y: Double(y*2+2), width: 2, height: 2).fill()
            }
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(calibratedRed: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255,
                  blue: Double(hex & 255)/255, alpha: 1)
    }
}
