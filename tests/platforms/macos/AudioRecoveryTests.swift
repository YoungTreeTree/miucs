import AppKit
import Foundation
import ScreenCaptureKit

private struct RecoveryTestError: Error { let message: String }

@MainActor
private final class FakeCapture: AudioCaptureSession {
    let frame: @Sendable (AudioFeatures, MelodyFrame?) -> Void
    let failure: @Sendable (Error) -> Void
    var holdStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var starts = 0, stops = 0
    var active = false
    private var stopRequested = false

    init(frame: @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void,
         failure: @escaping @Sendable (Error) -> Void) { self.frame = frame; self.failure = failure }
    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        active = !stopRequested
    }
    func stop() async { stops += 1; stopRequested = true; active = false }
    func finishStart() { holdStart = false; startContinuation?.resume(); startContinuation = nil }
    func fail(_ code: SCStreamError.Code = .failedApplicationConnectionInterrupted) {
        failure(NSError(domain: SCStreamErrorDomain, code: code.rawValue))
    }
    func emit(silent: Bool = false, amplitude: Double = 0.1) {
        frame(AudioFeatures(time: 0, sampleRate: 48_000, channelCount: 2,
            rms: silent ? 0 : amplitude, rmsDBFS: silent ? -240 : -20, peak: amplitude,
            crestDB: 0, envelope: silent ? 0 : amplitude, isSilent: silent, silenceDuration: silent ? 10 : 0,
            lowEnergy: 0, midEnergy: 0, highEnergy: 0, lowShare: nil, midShare: nil, highShare: nil,
            centroidHz: nil, bandwidthHz: nil, flatness: nil, spectralFlux: 0, onsetThreshold: 0.18,
            isOnset: false, balance: nil, sideEnergyRatio: nil, correlation: nil, displayBands: []), nil)
    }
}

private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 100.0
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@MainActor
private final class CaptureHarness {
    var captures = [FakeCapture]()
    var errors = [SCStreamError.Code]()
    var requests = 0, modes = [Bool]()
    var holdFactory = false, holdStart = false
    var factoryContinuation: CheckedContinuation<Void, Never>?
    nonisolated let clock = RecoveryClock()
    var expected = false, permission = true
    var outputChecks = 0
    var outputProbe: (@MainActor () async -> Bool)?
    var requestTimes = [Double]()

    func engine(timing: AudioRecoveryTiming? = nil, monitorsSystem: Bool = false) -> AudioEngine {
        var fast = AudioRecoveryTiming()
        fast.retryDelays = [0.02, 0.04, 0.08, 0.10]
        fast.restartDebounce = 0.025; fast.watchdogInterval = 0.01; fast.permissionPoll = 0.03
        return AudioEngine(factory: { [self] mode, frame, failure in
            requests += 1; modes.append(mode); requestTimes.append(ProcessInfo.processInfo.systemUptime)
            if !errors.isEmpty { throw NSError(domain: SCStreamErrorDomain, code: errors.removeFirst().rawValue) }
            if holdFactory { await withCheckedContinuation { factoryContinuation = $0 } }
            let capture = FakeCapture(frame: frame, failure: failure)
            capture.holdStart = holdStart
            captures.append(capture)
            return capture
        }, timing: timing ?? fast, monitorsSystem: monitorsSystem,
           now: { [clock] in clock.value }, audioExpected: { [self] in
               outputChecks += 1
               if let outputProbe { return await outputProbe() }
               return expected
           },
           permissionGranted: { [self] in permission })
    }
    func finishFactory() { holdFactory = false; factoryContinuation?.resume(); factoryContinuation = nil }
}

@main
@MainActor
struct AudioRecoveryTests {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw RecoveryTestError(message: message) }
    }
    static func pumpNotifications() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
    static func wait(_ predicate: () -> Bool, timeout: Double = 2) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            pumpNotifications()
            try await Task.sleep(for: .milliseconds(2))
        }
        try require(predicate(), "Timed out waiting for recovery")
    }
    static func settle(_ milliseconds: Int = 130) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

    static func main() async throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ body: @MainActor () async throws -> Void) async {
            do {
                try await body(); checks.append(["name": name, "passed": true]); print("PASS \(name)")
            } catch {
                checks.append(["name": name, "passed": false, "error": String(describing: error)])
                print("FAIL \(name): \(error)")
            }
        }
        await check("Interrupted capture reconnects and preserves capture scope") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start(excludingExistingApplications: true)
            h.captures[0].fail()
            try await wait { h.captures.count == 2 && engine.isRunning }
            try require(h.captures[0].stops > 0 && h.modes == [true, true], "Old capture was not stopped or scope changed")
        }
        await check("Startup failures back off and recover when a source returns") {
            let h = CaptureHarness(); h.errors = [.noCaptureSource, .noCaptureSource, .failedToStart]
            let engine = h.engine(); defer { engine.stop() }
            await engine.start()
            try await wait { h.requests == 4 && engine.isRunning }
            let intervals = zip(h.requestTimes.dropFirst(), h.requestTimes).map { $0 - $1 }
            try require(intervals[0] >= 0.015 && intervals[1] >= 0.035 && intervals[2] >= 0.075, "Retries did not back off")
        }
        await check("Sleep stops capture; wake recreates it exactly once") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start()
            engine.handleLifecycle(.sleep)
            try require(!engine.isRunning, "Capture continued during sleep")
            try await settle()
            try require(h.requests == 1, "Retry ran during sleep")
            engine.handleLifecycle(.wake); engine.handleLifecycle(.screensWake)
            try await wait { engine.isRunning && h.requests == 2 }
            try await settle()
            try require(h.requests == 2, "Duplicate wake created duplicate captures")
        }
        await check("Screen sleep waits for wake; system sleep remains authoritative") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start()
            engine.handleLifecycle(.sleep); engine.handleLifecycle(.screensSleep); engine.handleLifecycle(.screensWake)
            try await settle()
            try require(h.requests == 1 && !engine.isRunning, "Screen wake resumed a sleeping system")
            engine.handleLifecycle(.wake)
            try await wait { h.requests == 2 && engine.isRunning }
        }
        await check("Real workspace notification observers forward sleep and wake") {
            let h = CaptureHarness(), engine = h.engine(monitorsSystem: true); defer { engine.stop() }
            await engine.start()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            try await wait { !engine.isRunning }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await wait { h.requests == 2 && engine.isRunning }
        }
        await check("Display and output-route bursts are coalesced") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start()
            for _ in 0..<12 { engine.handleLifecycle(.configurationChanged) }
            try await wait { h.requests == 2 && engine.isRunning }
            try await settle()
            try require(h.requests == 2, "Configuration burst started multiple captures")
        }
        await check("Stop cancels pending retry and suppresses wake recovery") {
            let h = CaptureHarness(); h.errors = [.noCaptureSource]
            let engine = h.engine(); defer { engine.stop() }
            await engine.start(); engine.stop(); engine.handleLifecycle(.wake)
            try await settle()
            try require(h.requests == 1 && !engine.isRunning, "Stop was undone by retry")
            await engine.start()
            try require(engine.isRunning && h.requests == 2, "Explicit restart failed")
        }
        await check("macOS user-stop is respected until explicitly restarted") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start(); h.captures[0].fail(.userStopped)
            try await wait { !engine.isRunning }
            engine.handleLifecycle(.configurationChanged); engine.handleLifecycle(.wake)
            try await settle()
            try require(h.requests == 1, "User's system stop was ignored")
        }
        await check("Explicit start works after stopping while asleep") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start(); engine.handleLifecycle(.sleep); engine.stop()
            engine.handleLifecycle(.wake)
            await engine.start()
            try require(engine.isRunning && h.requests == 2, "Stopped lifecycle retained its sleeping state")
        }
        await check("Permission denial polls without repeating capture requests") {
            let h = CaptureHarness(); h.errors = [.userDeclined]; h.permission = false
            let engine = h.engine(); defer { engine.stop() }
            await engine.start(); try await settle()
            try require(h.requests == 1 && !engine.isRunning, "Permission requests repeated")
            h.permission = true
            try await wait { h.requests == 2 && engine.isRunning }
        }
        await check("Idle output without PCM is not mistaken for a stalled capture") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start(); h.clock.value += 600
            try await settle()
            try require(h.requests == 1 && engine.isRunning, "Idle output triggered recovery")
        }
        await check("Silent PCM remains healthy for long periods") {
            let h = CaptureHarness(); h.expected = true
            let engine = h.engine(); defer { engine.stop() }
            await engine.start()
            for _ in 0..<80 {
                h.clock.value += 1; h.captures[0].emit(silent: true)
                try await settle(2)
            }
            try require(h.requests == 1 && engine.isRunning && engine.features?.isSilent == true, "Silence was treated as a disconnection")
        }
        await check("Missing PCM during active output automatically rebuilds capture") {
            let h = CaptureHarness(); h.expected = true
            let engine = h.engine(); defer { engine.stop() }
            await engine.start(); h.captures[0].emit(); try await settle(30)
            h.clock.value += 13
            try await wait { h.requests == 2 && engine.isRunning }
        }
        await check("Fresh PCM bypasses device queries while stalled PCM still triggers recovery") {
            let h = CaptureHarness(); h.expected = true
            let engine = h.engine(); defer { engine.stop() }
            await engine.start()
            for _ in 0..<30 {
                h.clock.value += 0.003; h.captures[0].emit()
                try await settle(2)
            }
            try require(h.outputChecks == 0 && h.requests == 1, "Healthy capture queried hardware or reconnected")
            h.clock.value += 13
            try await wait { h.requests == 2 && engine.isRunning }
            try require(h.outputChecks > 0, "Stalled capture never checked the output device")
        }
        await check("An old output-device query cannot affect a reconnected capture") {
            let h = CaptureHarness()
            var pending: CheckedContinuation<Bool, Never>?
            h.outputProbe = {
                guard h.outputChecks == 1 else { return false }
                return await withCheckedContinuation { pending = $0 }
            }
            let engine = h.engine(); defer { engine.stop() }
            await engine.start()
            try await wait { pending != nil }
            h.clock.value += 600
            await engine.reconnect(); h.captures[1].emit()
            let generation = engine.channel.snapshot?.sessionID
            pending?.resume(returning: true); pending = nil
            try await settle()
            try require(h.requests == 2 && engine.isRunning && engine.channel.snapshot?.sessionID == generation,
                        "A cancelled device query changed the new capture")
        }
        await check("Callbacks from old captures cannot change the new scene or reconnect it") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start(); let old = h.captures[0]
            await engine.reconnect()
            h.captures[1].emit(amplitude: 0.2)
            try await wait { engine.features != nil }
            old.emit(amplitude: 0.9); old.fail()
            try await settle()
            try require(h.requests == 2 && engine.features?.rms == 0.2 && engine.isRunning, "Old callback escaped its generation")
        }
        await check("Stopping a pending factory never starts a late capture") {
            let h = CaptureHarness(); h.holdFactory = true
            let engine = h.engine(); defer { engine.stop() }
            let start = Task { await engine.start() }
            try await wait { h.factoryContinuation != nil }
            engine.stop(); h.finishFactory(); await start.value
            try require(h.captures.count == 1 && h.captures[0].starts == 0 && h.captures[0].stops > 0 && !engine.isRunning, "Late factory resurrected capture")
        }
        await check("Stopping an in-flight start cleans up its late completion") {
            let h = CaptureHarness(); h.holdStart = true
            let engine = h.engine(); defer { engine.stop() }
            let start = Task { await engine.start() }
            try await wait { h.captures.first?.startContinuation != nil }
            engine.stop(); h.captures[0].finishStart(); await start.value
            try require(!engine.isRunning && !h.captures[0].active && h.captures[0].stops > 0, "Late start resurrected capture")
        }
        await check("A healthy interval restores the short retry delay") {
            let h = CaptureHarness(); h.errors = [.noCaptureSource, .noCaptureSource, .noCaptureSource]
            let engine = h.engine(); defer { engine.stop() }
            await engine.start(); try await wait { engine.isRunning }
            h.captures[0].emit(); try await wait { engine.features != nil }
            h.clock.value += 21; h.captures[0].emit(); try await settle(5)
            let start = ProcessInfo.processInfo.systemUptime
            h.captures[0].fail()
            try await wait { h.requests == 5 && engine.isRunning }
            try require(h.requestTimes.last! - start < 0.075, "Healthy stream retained a long retry delay")
        }
        await check("Vocal source switches replace the capture once and respect a stopped engine") {
            let h = CaptureHarness(), engine = h.engine(); defer { engine.stop() }
            await engine.start(); h.captures[0].emit()
            let previous = engine.channel.snapshot?.sessionID
            await engine.setVocalSeparationEnabled(false)
            h.captures[1].emit()
            try require(h.requests == 2 && h.captures[0].stops > 0 && !engine.vocalSeparationEnabled &&
                        engine.channel.snapshot?.sessionID != previous, "Source switch did not create a fresh generation")
            await engine.setVocalSeparationEnabled(false)
            try require(h.requests == 2, "Identical selection reconnected unnecessarily")
            engine.stop()
            await engine.setVocalSeparationEnabled(true)
            try require(h.requests == 2 && !engine.isRunning, "Changing a stopped source started capture")
        }
        await check("A replacement survives the old in-flight start completing later") {
            let h = CaptureHarness(); h.holdStart = true
            let engine = h.engine(); defer { engine.stop() }
            let originalStart = Task { await engine.start() }
            try await wait { h.captures.first?.startContinuation != nil }
            h.holdStart = false
            await engine.reconnect()
            h.captures[1].emit(amplitude: 0.3)
            try await wait { engine.features != nil }
            h.captures[0].finishStart(); await originalStart.value
            h.captures[0].fail(); try await settle()
            try require(h.requests == 2 && engine.isRunning && h.captures[1].active && !h.captures[0].active && engine.features?.rms == 0.3,
                        "Late start damaged the replacement")
        }
        let failures = checks.filter { $0["passed"] as? Bool == false }.count
        let report: [String: Any] = ["passed": checks.count - failures, "failed": failures, "checks": checks,
                                    "method": "injected capture transport, actual retry tasks, workspace notifications and controlled monotonic clock; no machine sleep or device changes"]
        try FileManager.default.createDirectory(atPath: "docs/validation", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/audio-recovery-tests.json"))
        if failures > 0 { exit(1) }
    }
}
