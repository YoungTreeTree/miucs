import AppKit

/// A transparent, nonactivating desktop drawing. Default input behavior is click-through.
@MainActor
final class VisualizerPanel: NSPanel {
    private let flightView: PencilFlightView
    private let preferences: UserDefaults
    private let persistsFrame: Bool
    private(set) var isAdjustingPosition = false
    var onSizeChange: (() -> Void)?
    var drawingScale: Double { frame.width / 400 }

    init(engine: AudioEngine, preferences: UserDefaults = .standard, persistsFrame: Bool = true) {
        flightView = PencilFlightView(engine: engine)
        self.preferences = preferences
        self.persistsFrame = persistsFrame
        super.init(contentRect: NSRect(x: 80, y: 80, width: 400, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Miucs · Pencil Flight"
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        contentView = flightView
        flightView.autoresizingMask = [.width, .height]
        var restored = false
        if persistsFrame {
            setFrameAutosaveName("MiucsPencilFlight")
            restored = setFrameUsingName("MiucsPencilFlight")
        }
        if !restored, let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 28,
                                   y: screen.visibleFrame.minY + 28))
        }
        let savedWidth = preferences.object(forKey: "MiucsPencilFlightWidth") as? Double ?? 400
        setDrawingWidth(savedWidth, persist: false)
    }

    override var canBecomeKey: Bool { false }

    /// Uniform scale, bounded by the current display; never stretches the artwork.
    func setDrawingWidth(_ requested: Double, topLeft: NSPoint? = nil, persist: Bool = true) {
        guard requested.isFinite else { return }
        let screen = NSScreen.screens.max { a, b in
            let aRect = a.visibleFrame.intersection(frame), bRect = b.visibleFrame.intersection(frame)
            let aArea = aRect.isNull ? 0 : aRect.width * aRect.height
            let bArea = bRect.isNull ? 0 : bRect.width * bRect.height
            return aArea < bArea
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maximum = min(1000, min(visible.width, visible.height * 400 / 260))
        let width = min(max(requested, min(280, maximum)), maximum)
        let height = width * 260 / 400
        let anchor = topLeft ?? NSPoint(x: frame.minX, y: frame.maxY)
        let origin = NSPoint(x: min(max(anchor.x, visible.minX), visible.maxX - width),
                             y: min(max(anchor.y - height, visible.minY), visible.maxY - height))
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        onSizeChange?()
        if persist { saveDrawingFrame() }
    }

    func saveDrawingFrame() {
        preferences.set(frame.width, forKey: "MiucsPencilFlightWidth")
        if persistsFrame { saveFrame(usingName: "MiucsPencilFlight") }
    }

    func setAdjustingPosition(_ adjusting: Bool) {
        isAdjustingPosition = adjusting
        ignoresMouseEvents = !adjusting
        flightView.adjustingPosition = adjusting
        if adjusting { orderFrontRegardless() }
        else { saveDrawingFrame() }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        flightView.setRendering(true)
    }

    override func orderOut(_ sender: Any?) {
        setAdjustingPosition(false)
        flightView.setRendering(false)
        super.orderOut(sender)
    }
}
