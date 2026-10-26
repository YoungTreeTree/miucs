import AppKit
import QuartzCore

@MainActor
final class VisualizationHostView: NSView {
    let controller: VisualizationController
    private var frameLink: CADisplayLink?
    private lazy var frameTarget = HostFrameTarget(view: self)
    private var lastTick = 0.0
    private let overlay = HostOverlayView()
    private var resizeStartFrame: NSRect?
    private var resizeStartMouse = NSPoint.zero
    var adjustingPosition = false {
        didSet {
            if !adjustingPosition { resizeStartFrame = nil }
            overlay.adjustingPosition = adjustingPosition; overlay.needsDisplay = true
        }
    }
    var activeView: NSView? { (controller.current as? any MacVisualizationSession)?.view }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(source: any AudioFeatureSource, registry: VisualizationRegistry, selectedID: String,
         keyboardSource: (any KeyboardFeatureSource)? = nil) {
        controller = VisualizationController(source: source, registry: registry, keyboardSource: keyboardSource)
        let layout = registry.descriptor(id: selectedID)?.layout ?? .desktop
        super.init(frame: NSRect(x: 0, y: 0, width: layout.width, height: layout.height))
        wantsLayer = true; layer?.isOpaque = false; layer?.backgroundColor = NSColor.clear.cgColor
        _ = select(id: selectedID)
        overlay.frame = bounds; overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func select(id: String) -> Bool {
        let previous = activeView
        guard controller.select(id: id) else { return false }
        guard let view = activeView else { preconditionFailure("Register a native macOS adapter") }
        if previous !== view {
            previous?.removeFromSuperview()
            view.frame = bounds; view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: overlay.superview == nil ? nil : overlay)
            view.needsDisplay = true
        }
        overlay.layout = controller.current!.descriptor.layout
        overlay.needsDisplay = true
        updateViewport()
        return true
    }
    func presentSettings() { (controller.current as? any MacVisualizationSession)?.presentSettings() }
    var settingsTitle: String? { (controller.current as? any MacVisualizationSession)?.settingsTitle }
    func applyAppearance(_ appearance: VisualizationAppearance) {
        controller.applyAppearance(appearance)
        overlay.ink = appearance.ink.nsColor; overlay.needsDisplay = true
    }
    func dispose() {
        setRendering(false); activeView?.removeFromSuperview(); controller.dispose()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
    }
    func updateViewport() {
        let layout = controller.current?.descriptor.layout ?? .desktop
        controller.resize(to: VisualizationViewport(width: bounds.width, height: bounds.height, scale: bounds.width / layout.width))
    }
    func setRendering(_ active: Bool) {
        guard active else {
            frameLink?.invalidate(); frameLink = nil; controller.pause(); return
        }
        guard frameLink == nil else { return }
        controller.resume(); lastTick = 0
        let link = displayLink(target: frameTarget, selector: #selector(HostFrameTarget.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); frameLink = link
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { setRendering(false) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if adjustingPosition {
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }
        return super.hitTest(point)
    }
    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTick > 0 ? now - lastTick : link.targetTimestamp - link.timestamp
        lastTick = now
        if let input = controller.tick(deltaTime: max(dt, 0)), input.state != overlay.state {
            overlay.state = input.state; overlay.needsDisplay = true
        }
        if let color = (controller.current as? any MacVisualizationSession)?.hintColor, color != overlay.ink {
            overlay.ink = color; overlay.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard adjustingPosition, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.maxX - 30 && point.y >= bounds.maxY - 30 {
            resizeStartFrame = window.frame; resizeStartMouse = NSEvent.mouseLocation
        } else { window.performDrag(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard adjustingPosition, let initial = resizeStartFrame, let panel = window as? VisualizerPanel else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - resizeStartMouse.x, dy = resizeStartMouse.y - mouse.y
        let ratio = panel.drawingAspectRatio
        panel.setDrawingWidth(initial.width + (dx + dy * ratio) / (1 + ratio * ratio),
                              topLeft: NSPoint(x: initial.minX, y: initial.maxY), persist: false)
    }
    override func mouseUp(with event: NSEvent) {
        if resizeStartFrame != nil { (window as? VisualizerPanel)?.saveDrawingFrame() }
        resizeStartFrame = nil
    }
}

@MainActor
private final class HostFrameTarget: NSObject {
    weak var view: VisualizationHostView?
    init(view: VisualizationHostView) { self.view = view }
    @objc func frame(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }; view.tick(link)
    }
}

@MainActor
private final class HostOverlayView: NSView {
    var layout = VisualizationLayout.desktop
    var ink = NSColor(calibratedWhite: 0.24, alpha: 1)
    var state = AudioSourceState.connecting
    var adjustingPosition = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard adjustingPosition || state != .running else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let scale = NSAffineTransform(); scale.scaleX(by: bounds.width / layout.width, yBy: bounds.height / layout.height); scale.concat()
        let text: String
        if adjustingPosition { text = "拖动移动 · 右下角缩放 · 点击锁完成" }
        else {
            switch state {
            case .connecting: text = "正在连接声音…"
            case .recovering: text = "声音中断 · 正在自动恢复…"
            case .suspended: text = "等待系统唤醒…"
            case .permissionRequired: text = "等待系统音频授权…"
            case .userStopped: text = "捕获已停止 · 菜单栏可重新连接"
            default: text = "音频未连接 · 从菜单栏重新连接"
            }
        }
        let font = NSFont(name: "Bradley Hand", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(0.9),
            .strokeColor: NSColor(calibratedWhite: 0.98, alpha: 0.6), .strokeWidth: -3]
        let label = NSAttributedString(string: text, attributes: attributes)
        label.draw(at: NSPoint(x: max(18, (CGFloat(layout.width) - label.size().width) / 2), y: layout.height - 25))
        if adjustingPosition {
            NSColor(calibratedWhite: 0.45, alpha: 0.75).setStroke()
            let path = NSBezierPath(); path.lineWidth = 1
            for i in 0..<3 {
                path.move(to: NSPoint(x: layout.width - 26 + Double(i * 4), y: layout.height - 7))
                path.line(to: NSPoint(x: layout.width - 10, y: layout.height - 23 + Double(i * 4)))
            }
            path.stroke()
        }
    }
}
