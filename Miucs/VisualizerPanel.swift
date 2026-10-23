import AppKit

/// A transparent, nonactivating desktop drawing. Default input behavior is click-through.
@MainActor
final class VisualizerPanel: NSPanel, NSWindowDelegate {
    private static let savedFrameKey = "MiucsPencilFlightFrame"
    private let flightView: PencilFlightView
    private let paletteStore: PencilPaletteStore
    private let preferences: UserDefaults
    private let persistsFrame: Bool
    private var isRestoringFrame = true
    private var isUpdatingDrawingSize = false
    private(set) var isAdjustingPosition = false
    var onSizeChange: (() -> Void)?
    var drawingScale: Double { frame.width / 400 }

    init(engine: AudioEngine, preferences: UserDefaults = .standard, persistsFrame: Bool = true,
         paletteStore: PencilPaletteStore? = nil) {
        let paletteStore = paletteStore ?? PencilPaletteStore(preferences: preferences)
        self.paletteStore = paletteStore
        flightView = PencilFlightView(engine: engine, paletteStore: paletteStore)
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
        if persistsFrame { setFrameAutosaveName("MiucsPencilFlight") }
        let savedFrame = readSavedFrame()
        if let savedFrame {
            setFrame(savedFrame, display: false)
            restored = true
        } else if persistsFrame {
            restored = setFrameUsingName("MiucsPencilFlight", force: true)
        }
        if !restored, let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 28,
                                   y: screen.visibleFrame.minY + 28))
        }
        let savedWidth = savedFrame.map { Double($0.width) } ?? (preferences.object(forKey: "MiucsPencilFlightWidth") as? Double) ?? 400
        setDrawingWidth(savedWidth, persist: false)
        delegate = self
        isRestoringFrame = false
        saveDrawingFrame()
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
        isUpdatingDrawingSize = true
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        isUpdatingDrawingSize = false
        onSizeChange?()
        if persist { saveDrawingFrame() }
    }

    func saveDrawingFrame() {
        guard !isRestoringFrame, !isUpdatingDrawingSize,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        preferences.set(["x": frame.minX, "y": frame.minY,
                         "width": frame.width, "height": frame.height], forKey: Self.savedFrameKey)
        preferences.set(frame.width, forKey: "MiucsPencilFlightWidth")
        if persistsFrame { saveFrame(usingName: "MiucsPencilFlight") }
    }

    private func readSavedFrame() -> NSRect? {
        guard let saved = preferences.dictionary(forKey: Self.savedFrameKey),
              let x = saved["x"] as? Double, let y = saved["y"] as? Double,
              let width = saved["width"] as? Double, let height = saved["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func windowDidMove(_ notification: Notification) { saveDrawingFrame() }
    func windowDidResize(_ notification: Notification) { saveDrawingFrame() }
    func windowWillClose(_ notification: Notification) { saveDrawingFrame() }

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
