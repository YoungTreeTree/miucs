import AppKit

/// A transparent, nonactivating desktop canvas with independent module geometry.
@MainActor
final class VisualizerPanel: NSPanel, NSWindowDelegate {
    static let selectionPreferencesKey = "MiucsSelectedVisualization.v1"
    static func framePreferencesKey(for id: String) -> String {
        "MiucsVisualizationFrame.v1.\(id)"
    }
    private static func autosaveName(for id: String) -> String {
        "MiucsVisualization.\(id)"
    }
    let visualizationHost: VisualizationHostView
    private let preferences: UserDefaults
    private let persistsFrame: Bool
    private let monitorsHover: Bool
    private(set) var descriptor: VisualizationDescriptor
    private var isRestoringFrame = true
    private var isUpdatingDrawingSize = false
    private(set) var isAdjustingPosition = false
    var onSizeChange: (() -> Void)?
    var onAdjustmentChange: (() -> Void)?
    private var hoverDwell = HoverLockDwell()
    private var hoverSuspensionReasons = Set<String>()
    private var hoverTimer: Timer?
    private lazy var hoverTimerTarget = HoverLockTimerTarget(panel: self)
    private(set) var hoverLockPanel: HoverLockPanel?

    var drawingScale: Double { frame.width / descriptor.layout.width }
    var drawingAspectRatio: Double { descriptor.layout.aspectRatio }

    init(source: any AudioFeatureSource, registry: VisualizationRegistry, selectedID: String? = nil,
         preferences: UserDefaults = .standard, persistsFrame: Bool = true,
         keyboardSource: (any KeyboardFeatureSource)? = nil, monitorsHover: Bool = true) {
        let requestedID = selectedID ?? preferences.string(forKey: Self.selectionPreferencesKey)
        let initial = requestedID.flatMap { registry.descriptor(id: $0) } ?? registry.descriptor(id: PluginVisualizations.defaultID) ?? registry.descriptors.first!
        descriptor = initial
        visualizationHost = VisualizationHostView(source: source, registry: registry, selectedID: initial.id,
                                                   keyboardSource: keyboardSource)
        self.preferences = preferences; self.persistsFrame = persistsFrame
        self.monitorsHover = monitorsHover
        super.init(contentRect: NSRect(x: 80, y: 80, width: initial.layout.width, height: initial.layout.height),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        updateTitle()
        isFloatingPanel = true; level = .floating
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        contentView = visualizationHost
        visualizationHost.autoresizingMask = [.width, .height]
        restoreGeometry(fallbackTopLeft: nil)
        delegate = self
        isRestoringFrame = false
        saveDrawingFrame()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Selector-based notification observers are zeroing-weak; no token closure retains this panel.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: name, object: nil)
        }
    }

    override var canBecomeKey: Bool { false }

    @discardableResult
    func selectVisualization(id: String) -> Bool {
        guard let next = visualizationHost.controller.registry.descriptor(id: id) else { return false }
        guard next.id != descriptor.id else { return true }
        hideHoverLock()
        saveDrawingFrame()
        let anchor = NSPoint(x: frame.minX, y: frame.maxY)
        let wasRendering = visualizationHost.controller.isActive
        visualizationHost.setRendering(false)
        isRestoringFrame = true
        if persistsFrame { setFrameAutosaveName("") }
        guard visualizationHost.select(id: id) else {
            isRestoringFrame = false
            if persistsFrame { setFrameAutosaveName(Self.autosaveName(for: descriptor.id)) }
            if wasRendering { visualizationHost.setRendering(true) }
            return false
        }
        descriptor = next; updateTitle()
        restoreGeometry(fallbackTopLeft: anchor)
        isRestoringFrame = false
        saveDrawingFrame()
        if wasRendering { visualizationHost.setRendering(true) }
        if isAdjustingPosition { showHoverLock() }
        return true
    }

    private func updateTitle() {
        title = "Miucs · \(descriptor.name)"
    }

    private func restoreGeometry(fallbackTopLeft: NSPoint?) {
        let saved = readSavedFrame()
        var restored = false
        if let saved { setFrame(saved, display: false); restored = true }
        else if persistsFrame {
            restored = setFrameUsingName(Self.autosaveName(for: descriptor.id), force: true)
        }
        let layout = descriptor.layout
        if !restored {
            let screen = visibleFrame()
            let topLeft = fallbackTopLeft ?? NSPoint(x: screen.maxX - layout.width - 28,
                                                     y: screen.minY + layout.height + 28)
            setFrame(NSRect(x: topLeft.x, y: topLeft.y - layout.height,
                            width: layout.width, height: layout.height), display: false)
        }
        let width: Double = saved.map { Double($0.width) } ?? (restored ? Double(frame.width) : layout.width)
        setDrawingWidth(width, persist: false)
        visualizationHost.updateViewport()
        if persistsFrame { setFrameAutosaveName(Self.autosaveName(for: descriptor.id)) }
    }

    private func visibleFrame() -> NSRect {
        let screen = NSScreen.screens.max { a, b in
            let x = a.visibleFrame.intersection(frame), y = b.visibleFrame.intersection(frame)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Scale uniformly using this module's logical size, bounded by its current display.
    func setDrawingWidth(_ requested: Double, topLeft: NSPoint? = nil, persist: Bool = true) {
        guard requested.isFinite else { return }
        let layout = descriptor.layout, visible = visibleFrame()
        let maximum = min(layout.maximumWidth, min(Double(visible.width), Double(visible.height) / layout.aspectRatio))
        let width = min(max(requested, min(layout.minimumWidth, maximum)), maximum)
        let height = width * layout.aspectRatio
        let anchor = topLeft ?? NSPoint(x: frame.minX, y: frame.maxY)
        let origin = NSPoint(x: min(max(anchor.x, visible.minX), visible.maxX - width),
                             y: min(max(anchor.y - height, visible.minY), visible.maxY - height))
        isUpdatingDrawingSize = true
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        isUpdatingDrawingSize = false
        positionHoverLock()
        onSizeChange?()
        if persist { saveDrawingFrame() }
    }

    func saveDrawingFrame() {
        guard !isRestoringFrame, !isUpdatingDrawingSize,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        preferences.set(["x": frame.minX, "y": frame.minY,
                         "width": frame.width, "height": frame.height], forKey: Self.framePreferencesKey(for: descriptor.id))
        preferences.set(descriptor.id, forKey: Self.selectionPreferencesKey)
        if persistsFrame { saveFrame(usingName: Self.autosaveName(for: descriptor.id)) }
    }

    private func readSavedFrame() -> NSRect? {
        guard let saved = preferences.dictionary(forKey: Self.framePreferencesKey(for: descriptor.id)),
              let x = saved["x"] as? Double, let y = saved["y"] as? Double,
              let width = saved["width"] as? Double, let height = saved["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func windowDidMove(_ notification: Notification) { positionHoverLock(); saveDrawingFrame() }
    func windowDidResize(_ notification: Notification) { positionHoverLock(); saveDrawingFrame() }
    func windowWillClose(_ notification: Notification) {
        stopHoverLock(); visualizationHost.setRendering(false); saveDrawingFrame()
    }
    func setAdjustingPosition(_ adjusting: Bool) {
        let adjusting = adjusting && hoverSuspensionReasons.isEmpty
        isAdjustingPosition = adjusting; ignoresMouseEvents = !adjusting
        visualizationHost.adjustingPosition = adjusting
        hoverLockPanel?.lockButton.unlocked = adjusting
        onAdjustmentChange?()
        if adjusting { orderFrontRegardless(); showHoverLock() } else { saveDrawingFrame() }
    }
    override func orderFrontRegardless() {
        super.orderFrontRegardless(); visualizationHost.setRendering(true)
        startHoverSampling()
    }
    private func startHoverSampling() {
        guard monitorsHover, hoverTimer == nil, hoverSuspensionReasons.isEmpty else { return }
        let timer = Timer(timeInterval: 0.1, target: hoverTimerTarget,
                          selector: #selector(HoverLockTimerTarget.tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common); hoverTimer = timer
    }
    override func orderOut(_ sender: Any?) {
        stopHoverLock()
        setAdjustingPosition(false); visualizationHost.setRendering(false); super.orderOut(sender)
    }
    private func stopHoverLock() {
        hoverTimer?.invalidate(); hoverTimer = nil; hideHoverLock()
    }
    private func hideHoverLock() {
        hoverDwell.reset()
        if let control = hoverLockPanel { removeChildWindow(control); control.orderOut(nil) }
    }
    @objc private func displaysChanged() {
        hideHoverLock(); setAdjustingPosition(false); setDrawingWidth(frame.width)
    }
    @objc private func workspaceStateChanged(_ notification: Notification) {
        let reason: String
        let suspended: Bool
        switch notification.name {
        case NSWorkspace.willSleepNotification: reason = "system"; suspended = true
        case NSWorkspace.didWakeNotification: reason = "system"; suspended = false
        case NSWorkspace.screensDidSleepNotification: reason = "screen"; suspended = true
        case NSWorkspace.screensDidWakeNotification: reason = "screen"; suspended = false
        case NSWorkspace.sessionDidResignActiveNotification: reason = "session"; suspended = true
        case NSWorkspace.sessionDidBecomeActiveNotification: reason = "session"; suspended = false
        default: return
        }
        if suspended {
            hoverSuspensionReasons.insert(reason)
            stopHoverLock(); setAdjustingPosition(false)
        } else {
            hoverSuspensionReasons.remove(reason)
            if hoverSuspensionReasons.isEmpty, isVisible { startHoverSampling() }
        }
    }
    func sampleHoverLock() {
        updateHoverLock(pointer: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                        enabled: isVisible && !NSApp.isHidden)
    }
    /// Explicit input makes dwell/leave and lifecycle behavior deterministic in native tests.
    func updateHoverLock(pointer: NSPoint, now: TimeInterval, enabled: Bool) {
        guard enabled, hoverSuspensionReasons.isEmpty else { hideHoverLock(); return }
        let hovered = hoverDwell.update(inside: frame.contains(pointer), now: now)
        guard isAdjustingPosition || hovered else {
            if let control = hoverLockPanel, control.isVisible {
                removeChildWindow(control); control.orderOut(nil)
            }
            return
        }
        showHoverLock()
    }
    private func showHoverLock() {
        if hoverLockPanel == nil {
            let control = HoverLockPanel()
            control.lockButton.target = self; control.lockButton.action = #selector(toggleHoverLock)
            hoverLockPanel = control
        }
        guard let control = hoverLockPanel else { return }
        control.lockButton.unlocked = isAdjustingPosition
        positionHoverLock()
        if control.parent == nil { addChildWindow(control, ordered: .above) }
        if !control.isVisible { control.orderFrontRegardless() }
    }
    private func positionHoverLock() {
        guard let control = hoverLockPanel else { return }
        control.setFrameOrigin(NSPoint(x: frame.midX - 17, y: frame.maxY - frame.height * 0.28 - 17))
    }
    @objc func toggleHoverLock() { setAdjustingPosition(!isAdjustingPosition) }
}
