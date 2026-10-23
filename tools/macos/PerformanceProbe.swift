import AppKit

/// Synthetic scene only: no screen recording, system capture or personal content.
@main
@MainActor
enum PerformanceProbe {
    static func audio(_ t: Double, onset: Bool) -> AudioFeatures {
        AudioFeatures(time: t, sampleRate: 48_000, channelCount: 2, rms: 0.1, rmsDBFS: -20,
            peak: 0.3, crestDB: 9.5, envelope: 0.1, isSilent: false, silenceDuration: 0,
            lowEnergy: 0.005, midEnergy: 0.003, highEnergy: 0.004, lowShare: 0.4, midShare: 0.3,
            highShare: 0.3, centroidHz: 3000, bandwidthHz: 2000, flatness: 0.2,
            spectralFlux: onset ? 0.9 : 0.02, onsetThreshold: 0.2, isOnset: onset,
            balance: 0, sideEnergyRatio: 0.1, correlation: 0.8, displayBands: Array(repeating: 0.2, count: 24))
    }
    static func update(_ world: inout SoundFlightWorld, tick: Int) {
        let t = Double(tick) / 60
        world.receive(audio: audio(t, onset: tick % 15 == 0))
        let note = [60.0, 64, 67, 72, 76, 67][(tick / 23) % 6]
        world.receive(melody: MelodyFrame(time: t, pitchHz: 440 * pow(2, (note - 69) / 12), confidence: 1, isMelodic: true))
        world.advance(seconds: 1.0 / 60)
    }
    static func metrics(_ samples: [Double]) -> [String: Double] {
        let values = samples.sorted()
        return ["medianMs": values[values.count / 2] * 1000,
                "p95Ms": values[Int(Double(values.count - 1) * 0.95)] * 1000,
                "p99Ms": values[Int(Double(values.count - 1) * 0.99)] * 1000,
                "maxMs": values.last! * 1000,
                "meanMs": values.reduce(0, +) / Double(values.count) * 1000]
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if (3...5).contains(CommandLine.arguments.count) && ["--cadence", "--staff-cadence"].contains(CommandLine.arguments[1]) {
            let id = CommandLine.arguments[1] == "--staff-cadence" ? StaffNoteSimulation.module.id : BuiltInVisualizations.defaultID
            let width = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? .nan : 1000
            let duration = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? .nan : 6
            try cadence(to: URL(fileURLWithPath: CommandLine.arguments[2]), moduleID: id,
                        width: width, duration: duration); return
        }
        guard CommandLine.arguments.count == 2 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results = [[String: Any]]()
        for width in [400, 800, 1000] {
            let height = width * 260 / 400
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            var world = SoundFlightWorld(seed: 42)
            for tick in 0..<2700 { update(&world, tick: tick) }
            let view = PencilFlightView(preview: world)
            view.setFrameSize(NSSize(width: width, height: height))
            var updateTimes = [Double](), drawTimes = [Double]()
            var overBudget = 0
            for tick in 2700..<3360 {
                let times: (Double, Double) = autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    update(&world, tick: tick); view.updatePreview(world)
                    let updated = ProcessInfo.processInfo.systemUptime
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.clear(CGRect(x: 0, y: 0, width: width * 2, height: height * 2))
                    cg.translateBy(x: 0, y: Double(height * 2)); cg.scaleBy(x: 2, y: -2)
                    view.draw(view.bounds)
                    cg.restoreGState()
                    NSGraphicsContext.restoreGraphicsState()
                    return (updated - start, ProcessInfo.processInfo.systemUptime - updated)
                }
                // Warm drawing caches before recording steady-state costs.
                if tick >= 2760 {
                    updateTimes.append(times.0); drawTimes.append(times.1)
                    if times.0 + times.1 > 1.0 / 60 { overBudget += 1 }
                }
                if tick == 3300 {
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("flight-\(width).png"))
                    let first = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                    // The identical scene must render identically, including hand-drawn marks.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.clear(CGRect(x: 0, y: 0, width: width * 2, height: height * 2))
                    cg.translateBy(x: 0, y: Double(height * 2)); cg.scaleBy(x: 2, y: -2)
                    view.draw(view.bounds)
                    cg.restoreGState()
                    NSGraphicsContext.restoreGraphicsState()
                    let second = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                    guard first == second else { throw AudioAnalysisError.invalidInput("Static pencil marks flicker") }
                }
            }
            results.append(["widthPoints": width, "backingScale": 2, "frames": drawTimes.count,
                            "update": metrics(updateTimes), "draw": metrics(drawTimes),
                            "over16_67ms": overBudget, "staticSceneStable": true])
            print("\(width)pt draw p95: \(metrics(drawTimes)["p95Ms"]!) ms")
        }
        let report: [String: Any] = ["method": "600 steady-state synthetic frames per size, 2x bitmap; same retained production view; world warmed past 30s adaptive range; excludes WindowServer/presentation",
                                    "sizes": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("performance.json"))
    }

    static func cadence(to destination: URL, moduleID: String, width: Double = 1000, duration: Double = 6) throws {
        guard width.isFinite, width > 0, duration.isFinite, (3...60).contains(duration) else {
            throw AudioAnalysisError.invalidInput("Cadence expects a positive width and a measurement duration of 3...60 seconds")
        }
        guard CGDisplayIsActive(CGMainDisplayID()) != 0, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            throw AudioAnalysisError.invalidInput("Native cadence needs an awake display; macOS pauses display-link callbacks while the display sleeps")
        }
        let suite = "MiucsPerformance-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = AudioEngine(factory: { _, frame, _ in ProbeCapture(onFrame: frame) }, monitorsSystem: false)
        let panel = VisualizerPanel(source: engine.channel, registry: BuiltInVisualizations.registry(preferences: preferences), selectedID: moduleID, preferences: preferences, persistsFrame: false)
        panel.setDrawingWidth(width)
        func setProbe(_ handler: ((Double, Double) -> Void)?) {
            if let view = panel.visualizationHost.activeView as? PencilFlightView { view.onRender = handler }
            if let view = panel.visualizationHost.activeView as? StaffNoteView { view.onRender = handler }
        }
        var timestamps = [Double](), costs = [Double]()
        let warm = ProcessInfo.processInfo.systemUptime + 1
        setProbe { cost, timestamp in
            if timestamp >= warm { timestamps.append(timestamp); costs.append(cost) }
        }
        panel.orderFrontRegardless()
        Task { await engine.start() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration + 1))
        panel.orderOut(nil)
        // AppKit may finish a display invalidation already queued before hiding.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let stoppedCount = timestamps.count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let hiddenStopped = timestamps.count == stoppedCount
        var resumedFrames = 0
        setProbe { _, _ in resumedFrames += 1 }
        panel.orderFrontRegardless(); panel.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        let deliveredFrames = engine.channel.snapshot?.sequence ?? 0
        let sourceRunning = engine.isRunning
        engine.stop(); panel.orderOut(nil); setProbe(nil)
        let intervals = zip(timestamps.dropFirst(), timestamps).map { $0 - $1 }
        guard intervals.count > 100 else {
            throw AudioAnalysisError.invalidInput("Display link did not render enough frames: module=\(moduleID), recorded=\(timestamps.count), resumed=\(resumedFrames), snapshot=\(deliveredFrames), running=\(sourceRunning)")
        }
        let longFrames = intervals.enumerated().filter { $0.element > 0.025 }.map { item in
            ["atSeconds": timestamps[item.offset + 1] - warm, "intervalMs": item.element * 1000,
             "previousDrawMs": costs[item.offset] * 1000, "currentDrawMs": costs[item.offset + 1] * 1000]
        }
        let report: [String: Any] = ["method": "real native transparent window; synthetic capture transport; 1s warmup; no recording",
            "moduleID": moduleID, "widthPoints": panel.frame.width, "frames": timestamps.count,
            "measurementSeconds": duration,
            "fps": Double(intervals.count) / intervals.reduce(0, +), "interval": metrics(intervals),
            "draw": metrics(costs), "intervalsOver25ms": intervals.filter { $0 > 0.025 }.count,
            "drawsOver16_67ms": costs.filter { $0 > 1.0 / 60 }.count, "longFrames": longFrames,
            "hiddenStopsRendering": hiddenStopped, "resumedFramesInOneSecond": resumedFrames]
        guard hiddenStopped && (30...75).contains(resumedFrames) else {
            throw AudioAnalysisError.invalidInput("Hide/show: hiddenStopped=\(hiddenStopped), resumedFrames=\(resumedFrames)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        print("Native cadence: \(report["fps"]!) fps, \(report["intervalsOver25ms"]!) intervals >25ms")
    }
}

@MainActor
private final class ProbeCapture: AudioCaptureSession {
    private let onFrame: @Sendable (AudioFeatures, MelodyFrame?) -> Void
    private var timer: Timer?
    private var tick = 0
    init(onFrame: @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void) { self.onFrame = onFrame }
    func start() async throws {
        let timer = Timer(timeInterval: 1.0 / 47, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let time = Double(self.tick) / 47
                let note = [60.0, 67, 72, 76][(self.tick / 24) % 4]
                self.onFrame(PerformanceProbe.audio(time, onset: self.tick % 12 == 0),
                    MelodyFrame(time: time, pitchHz: 440 * pow(2, (note - 69) / 12), confidence: 1, isMelodic: true))
                self.tick += 1
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() async { timer?.invalidate(); timer = nil }
}
