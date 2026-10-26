import AppKit

@MainActor
private final class HostCapture: AudioCaptureSession {
    var starts = 0, stops = 0
    var emit: (@Sendable (AudioFeatures, MelodyFrame?) -> Void)?
    func start() async throws { starts += 1 }
    func stop() async { stops += 1 }
}

@MainActor
private final class HostJournal {
    var disposals = [String]()
    var settingsClosed = false
}

@MainActor
private final class NativeProbe: MacVisualizationSession {
    let descriptor: VisualizationDescriptor
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
    let settingsTitle: String? = "Probe settings"
    private let journal: HostJournal
    private var settings: NSWindow?
    var active = false
    var lastInput: FeatureInput?
    var lastKeyboard: KeyboardInput?
    var viewport = VisualizationViewport.desktop
    init(id: String, journal: HostJournal) {
        descriptor = VisualizationDescriptor(id: id, name: id); self.journal = journal
    }
    func activate(viewport: VisualizationViewport) { active = true; self.viewport = viewport }
    func resize(to viewport: VisualizationViewport) { self.viewport = viewport }
    func update(input: FeatureInput, deltaTime: Double) { lastInput = input }
    func receive(keyboard: KeyboardInput) { lastKeyboard = keyboard }
    func deactivate() { active = false }
    func presentSettings() {
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        settings?.isReleasedWhenClosed = false
    }
    func dispose() {
        deactivate(); settings?.close(); settings = nil
        journal.settingsClosed = true; journal.disposals.append(descriptor.id)
    }
}

@main
@MainActor
enum VisualizationHostTests {
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        let suite = "MiucsHostTest-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var checks = [[String: Any]]()
        func check(_ name: String, _ value: Bool) {
            checks.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)")
        }
        let capture = HostCapture()
        let engine = AudioEngine(factory: { _, onFrame, _ in
            capture.emit = onFrame; return capture
        }, monitorsSystem: false, audioExpected: { false }, permissionGranted: { true })
        await engine.start()
        defer { engine.stop() }
        let registry = VisualizationRegistry(), journal = HostJournal()
        weak var firstSession: NativeProbe?
        weak var secondSession: NativeProbe?
        registry.register(VisualizationDescriptor(id: "first", name: "First")) {
            let session = NativeProbe(id: "first", journal: journal); firstSession = session; return session
        }
        registry.register(VisualizationDescriptor(id: "second", name: "Second")) {
            let session = NativeProbe(id: "second", journal: journal); secondSession = session; return session
        }
        let keyboard = KeyboardChannel(), keyboardID = UUID()
        keyboard.reset(sessionID: keyboardID, state: .running)
        let panel = VisualizerPanel(source: engine.channel, registry: registry, selectedID: "first",
                                    preferences: preferences, persistsFrame: false, keyboardSource: keyboard, monitorsHover: false)
        let host = panel.visualizationHost
        host.controller.resume()
        check("Host mounts only the active native module", host.activeView === firstSession?.view &&
            host.subviews.count == 2 && firstSession?.active == true)
        panel.setDrawingWidth(500)
        let frameKey = VisualizerPanel.framePreferencesKey(for: "first")
        let frame = panel.frame, saved = preferences.dictionary(forKey: frameKey)!
        check("Viewport follows the existing native window resize", firstSession?.viewport.width == panel.frame.width &&
            firstSession?.view.frame.size == host.bounds.size)
        host.presentSettings()
        let oldView = host.activeView
        var audio = AudioFeatures(time: 0, sampleRate: 48_000, channelCount: 2, rms: 0.1,
            rmsDBFS: -20, peak: 0.2, crestDB: 6, envelope: 0.1, isSilent: false,
            silenceDuration: 0, lowEnergy: 0.005, midEnergy: 0.003, highEnergy: 0.002,
            lowShare: 0.5, midShare: 0.3, highShare: 0.2, centroidHz: 2000, bandwidthHz: 1000,
            flatness: 0.1, spectralFlux: 0.9, onsetThreshold: 0.18, isOnset: true,
            balance: 0, sideEnergyRatio: 0, correlation: 1, displayBands: Array(repeating: 0.2, count: 24))
        capture.emit?(audio, nil)
        keyboard.publish(KeyboardRawEvent(kind: .pressed, keyCode: 0, modifiers: []), sessionID: keyboardID)
        let generation = engine.channel.snapshot!.sessionID
        let switched = host.select(id: "second")
        host.controller.tick(deltaTime: 1.0 / 60)
        check("Switch releases the old session, detaches its view and closes settings", switched && firstSession == nil &&
            oldView?.superview == nil && journal.settingsClosed && journal.disposals == ["first"])
        check("New native module starts without replaying previous effects", host.activeView === secondSession?.view &&
            host.subviews.count == 2 && secondSession?.lastInput?.onsets.isEmpty == true &&
            secondSession?.lastInput?.spectralFluxPeak == 0)
        check("Native module receives concurrent keyboard state without replaying old presses",
            secondSession?.lastKeyboard?.state == .running && secondSession?.lastKeyboard?.events.isEmpty == true &&
            secondSession?.lastKeyboard?.heldKeys.map(\.keyCode) == [0])
        check("Switch preserves the running audio capture and generation", engine.isRunning && capture.starts == 1 &&
            capture.stops == 0 && engine.channel.snapshot?.sessionID == generation)
        check("Module switch preserves geometry, transparency and click-through", panel.frame == frame &&
            NSDictionary(dictionary: saved).isEqual(to: preferences.dictionary(forKey: frameKey)!) &&
            panel.ignoresMouseEvents && !panel.isOpaque && panel.backgroundColor?.alphaComponent == 0)
        host.adjustingPosition = true
        check("Position adjustment belongs to the host even if a module accepts mouse input",
            host.hitTest(host.convert(NSPoint(x: 20, y: 20), to: host.superview)) === host)
        host.adjustingPosition = false
        audio.time = 0.02
        keyboard.publish(KeyboardRawEvent(kind: .released, keyCode: 0, modifiers: []), sessionID: keyboardID)
        capture.emit?(audio, nil); host.controller.tick(deltaTime: 1.0 / 60)
        check("Audio continues delivering fresh events to the replacement view", secondSession?.lastInput?.onsets.count == 1 &&
            secondSession?.lastInput?.frame?.sequence == 2)
        check("One native refresh delivers fresh keyboard and audio events together",
            secondSession?.lastKeyboard?.events.map(\.kind) == [.released] && secondSession?.lastInput?.onsets.count == 1)
        let noOp = host.select(id: "second"), invalid = host.select(id: "missing")
        check("Same and unknown IDs leave the current native view intact", noOp && !invalid &&
            host.activeView === secondSession?.view && journal.disposals == ["first"])
        // The pointer sampler needs no input-monitoring/accessibility permission and never
        // turns the whole locked canvas interactive to reveal the button.
        var dwell = HoverLockDwell()
        for step in 0..<30 { _ = dwell.update(inside: true, now: Double(step) / 10) }
        check("Lock dwell stays hidden before three continuous seconds", !dwell.isVisible)
        check("Lock dwell appears at three seconds", dwell.update(inside: true, now: 3))
        check("Leaving resets lock dwell immediately", !dwell.update(inside: false, now: 3.1))
        _ = dwell.update(inside: true, now: 4)
        check("Reentry starts a new dwell", !dwell.update(inside: true, now: 4.1))
        check("Sleep or a suspended sampler cannot satisfy hover dwell", !dwell.update(inside: true, now: 100))
        check("A reversed clock resets dwell", !dwell.update(inside: true, now: 99))
        let pointer = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        for step in 0...30 { panel.updateHoverLock(pointer: pointer, now: Double(step) / 10, enabled: true) }
        let lock = panel.hoverLockPanel
        check("Only a small child target becomes interactive on locked dwell", lock != nil &&
            lock?.parent === panel && lock?.frame.size == NSSize(width: 34, height: 34) &&
            lock?.ignoresMouseEvents == false && panel.ignoresMouseEvents)
        // Render the real NSButton view (including its coordinate orientation) for visual review.
        let previewDirectory = URL(fileURLWithPath: "build/hover-lock-preview")
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        for unlocked in [false, true] {
            let button = SketchLockButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
            button.unlocked = unlocked
            if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    previewDirectory.appendingPathComponent(unlocked ? "unlocked.png" : "locked.png"))
            }
        }
        var adjustmentChanges = 0
        panel.onAdjustmentChange = { adjustmentChanges += 1 }
        lock?.lockButton.performClick(nil)
        check("Lock button unlocks movement and resizing through the existing state", panel.isAdjustingPosition &&
            host.adjustingPosition && !panel.ignoresMouseEvents && lock?.lockButton.unlocked == true)
        panel.updateHoverLock(pointer: NSPoint(x: panel.frame.maxX + 200, y: panel.frame.maxY + 200), now: 3.1, enabled: true)
        check("Unlocked target remains visible after pointer leaves the canvas", lock?.isVisible == true && lock?.parent === panel)
        panel.updateHoverLock(pointer: pointer, now: 3.2, enabled: true)
        lock?.lockButton.performClick(nil)
        check("Second click relocks without flicker and updates menu observer", !panel.isAdjustingPosition &&
            !host.adjustingPosition && panel.ignoresMouseEvents && lock?.parent === panel && adjustmentChanges == 2)
        for _ in 0..<6 { lock?.lockButton.performClick(nil) }
        check("Repeated toggles remain synchronized", !panel.isAdjustingPosition && panel.ignoresMouseEvents &&
            lock?.lockButton.unlocked == false && adjustmentChanges == 8)
        panel.setDrawingWidth(panel.frame.width + 20)
        check("Lock target follows resized drawing and remains inside it", lock.map {
            abs($0.frame.midX - panel.frame.midX) < 0.01 && panel.frame.contains($0.frame)
        } ?? false)
        let persistedFrame = preferences.dictionary(forKey: frameKey)
        panel.setAdjustingPosition(true); panel.setAdjustingPosition(false)
        check("Lock changes preserve existing saved geometry", persistedFrame.map {
            NSDictionary(dictionary: $0).isEqual(to: preferences.dictionary(forKey: frameKey)!)
        } ?? false)
        panel.updateHoverLock(pointer: NSPoint(x: panel.frame.minX - 1, y: panel.frame.minY), now: 3.1, enabled: true)
        check("Pointer exit hides and detaches the interactive target", lock?.isVisible == false && lock?.parent == nil)
        panel.setAdjustingPosition(true)
        check("Menu adjustment immediately reveals the unlocked control without dwell", lock?.isVisible == true && lock?.lockButton.unlocked == true)
        panel.updateHoverLock(pointer: pointer, now: 4, enabled: false)
        check("Disabled canvas hides even an unlocked control", lock?.isVisible == false && lock?.parent == nil)
        panel.setAdjustingPosition(false)
        let newPointer = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.updateHoverLock(pointer: newPointer, now: 3.2, enabled: true)
        check("Pointer reentry does not immediately redisplay the lock", lock?.isVisible == false)
        for step in 33...63 { panel.updateHoverLock(pointer: newPointer, now: Double(step) / 10, enabled: true) }
        panel.setAdjustingPosition(true)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        check("Display reconfiguration resets the control rather than stranding a click target", lock?.isVisible == false &&
            lock?.parent == nil && panel.ignoresMouseEvents)
        for step in 70...100 { panel.updateHoverLock(pointer: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
                                                   now: Double(step) / 10, enabled: true) }
        panel.setAdjustingPosition(true)
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        check("Sleep and inactive session immediately relock and remove the target", panel.ignoresMouseEvents &&
            !panel.isAdjustingPosition && lock?.isVisible == false && lock?.parent == nil)
        workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for step in 110...140 { panel.updateHoverLock(pointer: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
                                                    now: Double(step) / 10, enabled: true) }
        panel.setAdjustingPosition(true)
        check("Partial resume cannot reveal target or unlock an inactive session", lock?.isVisible == false &&
            panel.ignoresMouseEvents && !panel.isAdjustingPosition)
        workspaceNotifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        panel.updateHoverLock(pointer: NSPoint(x: panel.frame.midX, y: panel.frame.midY), now: 15, enabled: true)
        check("Full resume begins with a fresh hidden dwell", lock?.isVisible == false && panel.ignoresMouseEvents)
        for step in 151...180 { panel.updateHoverLock(pointer: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
                                                    now: Double(step) / 10, enabled: true) }
        check("Continuous hover after full resume reveals a locked target", lock?.parent === panel &&
            lock?.isVisible == true && panel.ignoresMouseEvents)
        panel.orderOut(nil)
        check("Hiding locks drawing and removes the child target", panel.ignoresMouseEvents &&
            !panel.isAdjustingPosition && lock?.isVisible == false && lock?.parent == nil)
        check("Hiding the host pauses animation while capture continues", !host.controller.isActive &&
            secondSession?.active == false && engine.isRunning && capture.stops == 0)
        check("Hiding a native view leaves the keyboard channel running", keyboard.subscribe().read().state == .running)
        host.dispose()
        check("Explicit disposal releases the current native session", host.controller.current == nil &&
            secondSession == nil && host.subviews.count == 1 && journal.disposals == ["first", "second"])

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/visualization-host-tests.json"))
        if failures > 0 { exit(1) }
    }
}
