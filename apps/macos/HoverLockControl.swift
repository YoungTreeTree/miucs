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
    // Explicit top-down coordinates: NSButton's inherited orientation must not invert the lock.
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Reduce the drawing while preserving the forgiving 34-point click target.
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.scale(by: 0.7)
        transform.translateX(by: -17, yBy: -17)
        transform.concat()
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: 10.5, y: 16))
        outline.curve(to: NSPoint(x: 23.5, y: 15.7), controlPoint1: NSPoint(x: 14, y: 15.5), controlPoint2: NSPoint(x: 20, y: 16.1))
        outline.curve(to: NSPoint(x: 25, y: 18), controlPoint1: NSPoint(x: 24.5, y: 15.7), controlPoint2: NSPoint(x: 25, y: 16.6))
        outline.line(to: NSPoint(x: 24.7, y: 26))
        outline.curve(to: NSPoint(x: 22.8, y: 28), controlPoint1: NSPoint(x: 24.8, y: 27.4), controlPoint2: NSPoint(x: 24, y: 28.1))
        outline.line(to: NSPoint(x: 11, y: 27.7))
        outline.curve(to: NSPoint(x: 9.3, y: 26), controlPoint1: NSPoint(x: 9.7, y: 27.8), controlPoint2: NSPoint(x: 9.2, y: 27.2))
        outline.line(to: NSPoint(x: 9.5, y: 18)); outline.close()
        // Paper only inside the lock body; no rounded button tile around the drawing.
        NSColor(calibratedWhite: isHighlighted ? 0.89 : 0.98, alpha: 0.88).setFill()
        outline.fill()
        let shackle = NSBezierPath()
        shackle.move(to: NSPoint(x: 13, y: 15.7))
        shackle.line(to: NSPoint(x: 12.8, y: 11))
        shackle.curve(to: NSPoint(x: unlocked ? 24.4 : 21.7, y: unlocked ? 9.5 : 10.8),
                      controlPoint1: NSPoint(x: 12.5, y: unlocked ? 2.5 : 4.1),
                      controlPoint2: NSPoint(x: unlocked ? 24.6 : 22, y: unlocked ? 2.1 : 4.4))
        if !unlocked { shackle.line(to: NSPoint(x: 21.8, y: 15.8)) }
        let key = NSBezierPath(ovalIn: NSRect(x: 15.6, y: 19.7, width: 2.5, height: 2.6))
        key.move(to: NSPoint(x: 16.9, y: 22)); key.line(to: NSPoint(x: 16.8, y: 24.2))
        let ink = NSColor(calibratedWhite: 0.27, alpha: isHighlighted ? 1 : 0.9)
        for path in [outline, shackle, key] {
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            NSColor(calibratedWhite: 0.98, alpha: 0.78).setStroke()
            path.lineWidth = 3.2; path.stroke()
            ink.setStroke(); path.lineWidth = 1.25; path.stroke()
        }
        // Short, offset pencil echoes instead of a mechanically duplicated outline.
        let grain = NSBezierPath(); grain.lineWidth = 0.55; grain.lineCapStyle = .round
        grain.move(to: NSPoint(x: 10.8, y: 18.6)); grain.line(to: NSPoint(x: 10.6, y: 25.3))
        grain.move(to: NSPoint(x: 12, y: 29)); grain.line(to: NSPoint(x: 21.8, y: 29.2))
        grain.move(to: NSPoint(x: 14.3, y: 10.4))
        grain.curve(to: NSPoint(x: 19.7, y: 6.5), controlPoint1: NSPoint(x: 14.3, y: 7.6), controlPoint2: NSPoint(x: 16.6, y: 5.8))
        ink.withAlphaComponent(0.32).setStroke(); grain.stroke()
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
