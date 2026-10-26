import AppKit

/// Dwell time is continuous, including across frame changes, but never across sleep.
struct HoverLockDwell {
    private var enteredAt: TimeInterval?
    private var lastSample: TimeInterval?
    private(set) var isVisible = false

    mutating func reset() { enteredAt = nil; lastSample = nil; isVisible = false }
    mutating func update(inside: Bool, now: TimeInterval) -> Bool {
        guard inside, now.isFinite else { reset(); return false }
        if let lastSample, now < lastSample || now - lastSample > 0.5 { reset() }
        lastSample = now
        if enteredAt == nil { enteredAt = now }
        isVisible = now - (enteredAt ?? now) >= 3
        return isVisible
    }
}

/// Only this 34-point child window accepts clicks while the drawing remains click-through.
@MainActor
final class HoverLockPanel: NSPanel {
    let lockButton = SketchLockButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 34, height: 34), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isFloatingPanel = true; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = lockButton
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SketchLockButton: NSButton {
    var unlocked = false {
        didSet {
            guard oldValue != unlocked else { return }
            toolTip = unlocked ? "上锁 · 恢复鼠标穿透" : "开锁 · 移动与缩放"
            setAccessibilityLabel(toolTip)
            needsDisplay = true
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; title = ""; focusRingType = .none
        setButtonType(.momentaryChange)
        toolTip = "开锁 · 移动与缩放"; setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        // Slightly irregular double strokes keep the icon in the pencil visual language.
        NSColor(calibratedWhite: isHighlighted ? 0.86 : 0.98, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        NSColor(calibratedWhite: 0.24, alpha: 0.95).setStroke()
        let body = NSBezierPath(); body.lineWidth = 1.5; body.lineJoinStyle = .round; body.lineCapStyle = .round
        body.move(to: NSPoint(x: 10, y: 9)); body.line(to: NSPoint(x: 24, y: 9.5))
        body.line(to: NSPoint(x: 23.5, y: 21)); body.line(to: NSPoint(x: 10.5, y: 20.5)); body.close()
        body.stroke()
        let shackle = NSBezierPath(); shackle.lineWidth = 1.5; shackle.lineCapStyle = .round
        shackle.move(to: NSPoint(x: unlocked ? 16 : 12.5, y: 21))
        shackle.line(to: NSPoint(x: unlocked ? 16 : 12.5, y: 25))
        shackle.curve(to: NSPoint(x: unlocked ? 27 : 22, y: unlocked ? 25 : 24),
                      controlPoint1: NSPoint(x: unlocked ? 16 : 12.5, y: 32),
                      controlPoint2: NSPoint(x: unlocked ? 28 : 22, y: 32))
        if !unlocked { shackle.line(to: NSPoint(x: 22, y: 21)) }
        shackle.stroke()
        let detail = NSBezierPath(); detail.lineWidth = 0.6
        detail.move(to: NSPoint(x: 11, y: 8)); detail.line(to: NSPoint(x: 24.5, y: 8.5)); detail.stroke()
        NSColor(calibratedWhite: 0.24, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 15.5, y: 14, width: 3, height: 3)).fill()
        let key = NSBezierPath(); key.lineWidth = 1.2
        key.move(to: NSPoint(x: 17, y: 14)); key.line(to: NSPoint(x: 17, y: 12)); key.stroke()
    }
}

@MainActor
final class HoverLockTimerTarget: NSObject {
    weak var panel: VisualizerPanel?
    init(panel: VisualizerPanel) { self.panel = panel }
    @objc func tick(_ timer: Timer) {
        guard let panel else { timer.invalidate(); return }
        panel.sampleHoverLock()
    }
}
