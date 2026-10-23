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
    var viewport = VisualizationViewport.desktop
    init(id: String, journal: HostJournal) {
        descriptor = VisualizationDescriptor(id: id, name: id); self.journal = journal
    }
    func activate(viewport: VisualizationViewport) { active = true; self.viewport = viewport }
    func resize(to viewport: VisualizationViewport) { self.viewport = viewport }
    func update(input: FeatureInput, deltaTime: Double) { lastInput = input }
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
        let panel = VisualizerPanel(source: engine.channel, registry: registry, selectedID: "first",
                                    preferences: preferences, persistsFrame: false)
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
        let generation = engine.channel.snapshot!.sessionID
        let switched = host.select(id: "second")
        host.controller.tick(deltaTime: 1.0 / 60)
        check("Switch releases the old session, detaches its view and closes settings", switched && firstSession == nil &&
            oldView?.superview == nil && journal.settingsClosed && journal.disposals == ["first"])
        check("New native module starts without replaying previous effects", host.activeView === secondSession?.view &&
            host.subviews.count == 2 && secondSession?.lastInput?.onsets.isEmpty == true &&
            secondSession?.lastInput?.spectralFluxPeak == 0)
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
        capture.emit?(audio, nil); host.controller.tick(deltaTime: 1.0 / 60)
        check("Audio continues delivering fresh events to the replacement view", secondSession?.lastInput?.onsets.count == 1 &&
            secondSession?.lastInput?.frame?.sequence == 2)
        let noOp = host.select(id: "second"), invalid = host.select(id: "missing")
        check("Same and unknown IDs leave the current native view intact", noOp && !invalid &&
            host.activeView === secondSession?.view && journal.disposals == ["first"])
        panel.orderOut(nil)
        check("Hiding the host pauses animation while capture continues", !host.controller.isActive &&
            secondSession?.active == false && engine.isRunning && capture.stops == 0)
        host.dispose()
        check("Explicit disposal releases the current native session", host.controller.current == nil &&
            secondSession == nil && host.subviews.count == 1 && journal.disposals == ["first", "second"])

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/visualization-host-tests.json"))
        if failures > 0 { exit(1) }
    }
}
