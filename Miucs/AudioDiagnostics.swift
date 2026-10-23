import AppKit
import Combine
import Foundation

private struct AudioDiagnosticReport: Codable {
    var startedAt: String
    var status: String
    var message: String
    var fixture: String?
    var captureScope: String
    var playbackStartCaptureTime: Double?
    var capturedFrameCount: Int
    var frames: [AudioFeatures]
    var melodyFrames: [MelodyFrame]
}

/// Headless verification mode. Stores feature numbers, never captured PCM or screen images.
@MainActor
final class AudioDiagnostics {
    private let engine: AudioEngine
    private var subscription: AnyCancellable?
    private var frames = [AudioFeatures]()
    private var melodySubscription: AnyCancellable?
    private var melodyFrames = [MelodyFrame]()

    init(engine: AudioEngine) { self.engine = engine }

    /// Exercises actual SCStream teardown/recreation without putting the computer to sleep.
    /// The report contains counts only; no features from the user's system mix are retained.
    func runRecovery(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count else {
            fputs("Recovery verification requires --output <report.json>\n", stderr)
            NSApp.terminate(nil); return
        }
        let destination = URL(fileURLWithPath: arguments[index + 1])
        var count = 0, checks = [[String: Any]]()
        subscription = engine.$features.compactMap { $0 }.sink { _ in count += 1 }
        func awaitFrames(after previous: Int) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while (!engine.isRunning || count < previous + 5) && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            if !engine.isRunning || count < previous + 5 {
                throw AudioAnalysisError.invalidInput("Capture did not resume delivering audio")
            }
        }
        do {
            await engine.start()
            try await awaitFrames(after: 0)
            checks.append(["name": "Real system capture delivers audio", "passed": true])
            engine.handleLifecycle(.sleep)
            guard !engine.isRunning else { throw AudioAnalysisError.invalidInput("Capture did not suspend") }
            try await Task.sleep(for: .milliseconds(150))
            let beforeWake = count
            engine.handleLifecycle(.wake); engine.handleLifecycle(.screensWake)
            try await awaitFrames(after: beforeWake)
            checks.append(["name": "Real SCStream delivers audio after simulated sleep/wake", "passed": true])
            let beforeConfiguration = count
            engine.handleLifecycle(.configurationChanged)
            try await awaitFrames(after: beforeConfiguration)
            checks.append(["name": "Real SCStream delivers audio after configuration rebuild", "passed": true])
            engine.stop()
            let beforeStop = count
            try await Task.sleep(for: .milliseconds(1200))
            guard !engine.isRunning && count == beforeStop else {
                throw AudioAnalysisError.invalidInput("Stopped capture resumed unexpectedly")
            }
            checks.append(["name": "Explicit stop prevents further capture callbacks", "passed": true])
        } catch {
            checks.append(["name": "System recovery verification", "passed": false, "error": String(describing: error)])
        }
        subscription?.cancel(); engine.stop()
        let passed = checks.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["checks": checks, "passed": passed, "failed": checks.count - passed,
            "method": "real ScreenCaptureKit audio; simulated engine lifecycle events; no physical sleep or device change; counts only"]
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            print("System audio recovery: \(passed)/\(checks.count) passed")
        } catch { fputs("Cannot save recovery verification: \(error)\n", stderr) }
        NSApp.terminate(nil)
    }

    func run(arguments: [String]) async {
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let destination = argument("--output") else {
            fputs("Audio diagnostics requires --output <report.json>\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let fixture = argument("--fixture")
        let duration = min(max(Double(argument("--duration") ?? "8") ?? 8, 1), 60)
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var status = "completed", message = "Captured system audio features"
        var playbackStart: Double?
        subscription = engine.$features.compactMap { $0 }.sink { [weak self] frame in
            self?.frames.append(frame)
        }
        melodySubscription = engine.$melody.compactMap { $0 }
            .removeDuplicates(by: { $0.time == $1.time })
            .sink { [weak self] in self?.melodyFrames.append($0) }
        let isolateFixture = fixture != nil && arguments.contains("--isolate-fixture")
        await engine.start(excludingExistingApplications: isolateFixture)
        if !engine.isRunning {
            status = "capture-unavailable"
            message = engine.status
        } else {
            do {
                try await Task.sleep(for: .milliseconds(700))
                if let fixture {
                    guard FileManager.default.fileExists(atPath: fixture) else {
                        throw AudioAnalysisError.invalidInput("Fixture does not exist: \(fixture)")
                    }
                    let playback = Process()
                    playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                    playback.arguments = [fixture]
                    playbackStart = frames.last?.time
                    try playback.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + 60
                    while playback.isRunning && engine.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if playback.isRunning {
                        playback.terminate()
                        throw AudioAnalysisError.invalidInput("Playback timed out or capture stopped")
                    }
                    if playback.terminationStatus != 0 {
                        throw AudioAnalysisError.invalidInput("afplay exited with \(playback.terminationStatus)")
                    }
                    try await Task.sleep(for: .milliseconds(700))
                } else {
                    try await Task.sleep(for: .seconds(duration))
                }
                if !engine.isRunning {
                    status = "capture-interrupted"
                    message = engine.status
                } else if frames.isEmpty {
                    status = "no-audio-frames"
                    message = "Capture started but delivered no complete audio windows"
                }
            } catch {
                status = "diagnostic-failed"
                message = String(describing: error)
            }
        }
        subscription?.cancel()
        melodySubscription?.cancel()
        engine.stop()
        let report = AudioDiagnosticReport(
            startedAt: startedAt, status: status, message: message,
            fixture: fixture, captureScope: isolateFixture ? "exclude-existing-applications" : "system-mix",
            playbackStartCaptureTime: playbackStart,
            capturedFrameCount: frames.count, frames: frames, melodyFrames: melodyFrames
        )
        do {
            let destinationURL = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: destinationURL, options: .atomic)
            print("Audio diagnostics: \(status), \(frames.count) frames; \(destination)")
        } catch {
            fputs("Cannot save audio diagnostics: \(error)\n", stderr)
        }
        NSApp.terminate(nil)
    }
}
