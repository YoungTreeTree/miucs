import AppKit
import Darwin

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
    static func melody(_ time: Double, note: Double, tick: Int, withGaps: Bool) -> MelodyFrame {
        let voiced = !withGaps || tick % 10 >= 4
        return MelodyFrame(time: time, pitchHz: voiced ? 440 * pow(2, (note - 69) / 12) : nil,
                           confidence: voiced ? 1 : 0, isMelodic: voiced, estimator: withGaps ? .crepe : nil)
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments.count == 3, ["--staff-keyboard", "--staff-beats", "--staff-joins"].contains(CommandLine.arguments[1]) {
            try keyboardPerformance(to: URL(fileURLWithPath: CommandLine.arguments[2]), withBeats: CommandLine.arguments[1] != "--staff-keyboard",
                                    withGaps: CommandLine.arguments[1] == "--staff-joins"); return
        }
        if (3...5).contains(CommandLine.arguments.count) && ["--cadence", "--staff-cadence", "--staff-keyboard-cadence", "--staff-beats-cadence", "--staff-joins-cadence"].contains(CommandLine.arguments[1]) {
            let id = CommandLine.arguments[1] == "--cadence" ? BuiltInVisualizations.defaultID : StaffNoteSimulation.module.id
            let width = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? .nan : 1000
            let duration = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? .nan : 6
            try cadence(to: URL(fileURLWithPath: CommandLine.arguments[2]), moduleID: id,
                        width: width, duration: duration, withKeyboard: ["--staff-keyboard-cadence", "--staff-beats-cadence", "--staff-joins-cadence"].contains(CommandLine.arguments[1]),
                        withBeats: ["--staff-beats-cadence", "--staff-joins-cadence"].contains(CommandLine.arguments[1]),
                        withGaps: CommandLine.arguments[1] == "--staff-joins-cadence"); return
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

    static func keyboardPerformance(to destination: URL, withBeats: Bool = false, withGaps: Bool = false) throws {
        var results = [[String: Any]](), withinBudget = true
        for width in [600.0, 800, 1600] {
            for pattern in [SyntheticKeyboardInput.Pattern.typing20, .capacity] {
                let session = MacStaffNoteSession(), keyboard = SyntheticKeyboardInput(pattern), generation = UUID()
                let reader = keyboard.channel.subscribe()
                session.drawing.setFrameSize(NSSize(width: width, height: width / 5))
                session.activate(viewport: VisualizationViewport(width: width, height: width / 5, scale: width / 800))
                var updates = [Double](), submissions = [Double](), totals = [Double]()
                var cpuUpdates = [Double](), cpuSubmissions = [Double](), cpuTotals = [Double](), peak = 0, peakRings = 0, peakJoins = 0
                for tick in 0..<1140 {
                    let time = Double(tick) / 60
                    keyboard.update(at: time)
                    var a = audio(time, onset: tick % 12 == 0)
                    a.envelope = 0.07 * pow(10, 0.5 * sin(time * .pi))
                    let midi = [60.0, 62, 64, 67, 69, 72][(tick / 30) % 6]
                    let frame = AudioFeatureFrame(sessionID: generation, sequence: UInt64(tick + 1) * 4, receivedAt: time,
                        audio: a, melody: melody(time, note: midi, tick: tick, withGaps: withGaps))
                    let beatSequences: [UInt64] = withBeats && tick % (pattern == .capacity ? 30 : 20) == 0
                        ? (pattern == .capacity ? Array((frame.sequence - 3)...frame.sequence) : [frame.sequence]) : []
                    let input = FeatureInput(sessionID: generation, state: .running, frame: frame, frameAge: 0,
                        onsets: a.isOnset ? [AudioOnsetEvent(sequence: frame.sequence, time: time, receivedAt: time, strength: 0.9)] : [], spectralFluxPeak: 0.9,
                        beats: beatSequences.map { AudioBeatEvent(sequence: $0, time: time, receivedAt: time, strength: 1, bpm: 180, confidence: 1) })
                    let times: (Double, Double, Double, Double) = autoreleasepool {
                        let start = ProcessInfo.processInfo.systemUptime
                        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        session.receive(keyboard: reader.read()); session.update(input: input, deltaTime: 1.0 / 60)
                        let cpuUpdated = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        let updated = ProcessInfo.processInfo.systemUptime
                        session.drawing.updateLayer()
                        let cpuSubmitted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        return (updated - start, ProcessInfo.processInfo.systemUptime - updated,
                            Double(cpuUpdated - cpuStart) / 1e9, Double(cpuSubmitted - cpuUpdated) / 1e9)
                    }
                    if tick >= 540 {
                        updates.append(times.0); submissions.append(times.1); totals.append(times.0 + times.1)
                        cpuUpdates.append(times.2); cpuSubmissions.append(times.3); cpuTotals.append(times.2 + times.3)
                        peak = max(peak, session.simulation.keyboardStars.stars.count)
                        peakRings = max(peakRings, session.simulation.beatRings.rings.count)
                        peakJoins = max(peakJoins, session.simulation.scene.trace.filter {
                            $0.join.map { $0.progress(at: session.simulation.scene.elapsed) < 1 } ?? false
                        }.count)
                    }
                }
                let combined = metrics(totals), cpu = metrics(cpuTotals), passed = cpu["p95Ms"]! < 2
                withinBudget = withinBudget && passed && (pattern != .capacity || peak == 112) &&
                    (!withBeats || peakRings == (pattern == .capacity ? StaffBeatRings.limit : 11)) && (!withGaps || peakJoins >= 2)
                results.append(["widthPoints": width, "pattern": pattern.rawValue, "frames": totals.count,
                    "peakStars": peak, "peakRings": peakRings, "peakActiveJoins": peakJoins, "animationUpdate": metrics(updates), "layerSubmission": metrics(submissions),
                    "combined": combined, "threadCPUUpdate": metrics(cpuUpdates), "threadCPUSubmission": metrics(cpuSubmissions),
                    "threadCPUCombined": cpu, "p95Under2ms": passed, "wallP95Under2ms": combined["p95Ms"]! < 2])
                session.dispose()
                print("Staff keyboard \(width)pt \(pattern.rawValue): CPU p95 \(cpu["p95Ms"]!) ms, wall p95 \(combined["p95Ms"]!) ms, peak \(peak) stars")
            }
        }
        let report: [String: Any] = ["method": "600 measured synthetic frames after 9s warmup per size/pattern; production keyboard channel, native staff session and retained layer transactions; CLOCK_THREAD_CPUTIME_ID records main-thread CPU, systemUptime separately includes scheduling/commit waits; excludes WindowServer/GPU execution and presentation",
            "typingPressesPerSecond": 20, "burstLimit": 16, "starLimit": 112, "p95BudgetMs": 2,
            "withBeats": withBeats, "ringLimit": StaffBeatRings.limit,
            "beatStress": "180 BPM during typing; four simultaneous artificial pulses every 500ms in capacity case to saturate all twenty main/small arc slots",
            "withPitchGaps": withGaps, "pitchGapStress": "In gap mode, four unvoiced frames in every ten create overlapping joins while new notes continue",
            "passed": withinBudget, "scenarios": results]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        if !withinBudget { throw AudioAnalysisError.invalidInput("Staff keyboard CPU budget or capacity check failed") }
    }

    static func cadence(to destination: URL, moduleID: String, width: Double = 1000, duration: Double = 6,
                        withKeyboard: Bool = false, withBeats: Bool = false, withGaps: Bool = false) throws {
        guard width.isFinite, width > 0, duration.isFinite, (3...60).contains(duration) else {
            throw AudioAnalysisError.invalidInput("Cadence expects a positive width and a measurement duration of 3...60 seconds")
        }
        guard CGDisplayIsActive(CGMainDisplayID()) != 0, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            throw AudioAnalysisError.invalidInput("Native cadence needs an awake display; macOS pauses display-link callbacks while the display sleeps")
        }
        let suite = "MiucsPerformance-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let keyboard = withKeyboard ? SyntheticKeyboardInput(.typing20) : nil
        let engine = AudioEngine(factory: { _, frame, _ in ProbeCapture(onFrame: frame, onTick: { keyboard?.update(at: $0) }, withBeats: withBeats, withGaps: withGaps) }, monitorsSystem: false)
        let panel = VisualizerPanel(source: engine.channel, registry: BuiltInVisualizations.registry(preferences: preferences), selectedID: moduleID,
            preferences: preferences, persistsFrame: false, keyboardSource: keyboard?.channel)
        panel.setDrawingWidth(width)
        func setProbe(_ handler: ((Double, Double) -> Void)?) {
            if let view = panel.visualizationHost.activeView as? PencilFlightView { view.onRender = handler }
            if let view = panel.visualizationHost.activeView as? StaffNoteView { view.onRender = handler }
        }
        var timestamps = [Double](), costs = [Double](), ringFrames = 0, joiningFrames = 0
        let warm = ProcessInfo.processInfo.systemUptime + 1
        setProbe { cost, timestamp in
            if timestamp >= warm { timestamps.append(timestamp); costs.append(cost) }
            if let view = panel.visualizationHost.activeView as? StaffNoteView, !view.rings.isEmpty { ringFrames += 1 }
            if let view = panel.visualizationHost.activeView as? StaffNoteView,
               view.scene.trace.contains(where: { $0.join.map { $0.progress(at: view.scene.elapsed) < 1 } ?? false }) { joiningFrames += 1 }
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
            "syntheticKeyboardPresses": keyboard?.presses ?? 0, "keyboardPressesPerSecond": withKeyboard ? 20 : 0,
            "withBeats": withBeats, "framesWithRings": ringFrames,
            "withPitchGaps": withGaps, "framesWithActiveJoins": joiningFrames,
            "measurementSeconds": duration,
            "fps": Double(intervals.count) / intervals.reduce(0, +), "interval": metrics(intervals),
            "draw": metrics(costs), "intervalsOver25ms": intervals.filter { $0 > 0.025 }.count,
            "drawsOver16_67ms": costs.filter { $0 > 1.0 / 60 }.count, "longFrames": longFrames,
            "hiddenStopsRendering": hiddenStopped, "resumedFramesInOneSecond": resumedFrames]
        guard hiddenStopped && (30...75).contains(resumedFrames) && (!withBeats || ringFrames > 0) && (!withGaps || joiningFrames > 0) else {
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
    private let onTick: (Double) -> Void
    private var timer: Timer?
    private var tick = 0
    private let withBeats: Bool
    private let withGaps: Bool
    init(onFrame: @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void, onTick: @escaping (Double) -> Void = { _ in }, withBeats: Bool = false, withGaps: Bool = false) {
        self.onFrame = onFrame; self.onTick = onTick; self.withBeats = withBeats; self.withGaps = withGaps
    }
    func start() async throws {
        let timer = Timer(timeInterval: 1.0 / 47, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let time = Double(self.tick) / 47
                self.onTick(time)
                let note = [60.0, 67, 72, 76][(self.tick / 24) % 4]
                var audio = PerformanceProbe.audio(time, onset: self.tick % 12 == 0)
                if self.withBeats {
                    let beat = Int(floor(time * 2)) > Int(floor(Double(max(0, self.tick - 1)) / 47 * 2))
                    audio.beat = BeatFrame(time: time, bpm: 120, phase: (time * 2).truncatingRemainder(dividingBy: 1), confidence: 1,
                                           strength: 0.9, beatTime: beat ? floor(time * 2) / 2 : nil)
                }
                self.onFrame(audio, PerformanceProbe.melody(time, note: note, tick: self.tick, withGaps: self.withGaps))
                self.tick += 1
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() async { timer?.invalidate(); timer = nil }
}
