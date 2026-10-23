import AppKit
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

    init(engine: AudioEngine) { self.engine = engine }

    /// Exercises actual SCStream teardown/recreation without putting the computer to sleep.
    /// The report contains counts only; no features from the user's system mix are retained.
    func runRecovery(arguments: [String]) async {
        guard let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count else {
            fputs("Recovery verification requires --output <report.json>\n", stderr)
            NSApp.terminate(nil); return
        }
        let destination = URL(fileURLWithPath: arguments[index + 1])
        var checks = [[String: Any]]()
        engine.channel.startRecording()
        func awaitFrames(after previous: Int) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while (!engine.isRunning || engine.channel.recordedFrameCount < previous + 5) && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            if !engine.isRunning || engine.channel.recordedFrameCount < previous + 5 {
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
            let beforeWake = engine.channel.recordedFrameCount
            engine.handleLifecycle(.wake); engine.handleLifecycle(.screensWake)
            try await awaitFrames(after: beforeWake)
            checks.append(["name": "Real SCStream delivers audio after simulated sleep/wake", "passed": true])
            let beforeConfiguration = engine.channel.recordedFrameCount
            engine.handleLifecycle(.configurationChanged)
            try await awaitFrames(after: beforeConfiguration)
            checks.append(["name": "Real SCStream delivers audio after configuration rebuild", "passed": true])
            engine.stop()
            let beforeStop = engine.channel.recordedFrameCount
            try await Task.sleep(for: .milliseconds(1200))
            guard !engine.isRunning && engine.channel.recordedFrameCount == beforeStop else {
                throw AudioAnalysisError.invalidInput("Stopped capture resumed unexpectedly")
            }
            checks.append(["name": "Explicit stop prevents further capture callbacks", "passed": true])
        } catch {
            checks.append(["name": "System recovery verification", "passed": false, "error": String(describing: error)])
        }
        engine.stop(); _ = engine.channel.stopRecording()
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
        engine.channel.startRecording()
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
                    playbackStart = engine.features?.time
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
                } else if engine.channel.recordedFrameCount == 0 {
                    status = "no-audio-frames"
                    message = "Capture started but delivered no complete audio windows"
                }
            } catch {
                status = "diagnostic-failed"
                message = String(describing: error)
            }
        }
        engine.stop()
        let packets = engine.channel.stopRecording()
        let frames = packets.map(\.audio)
        var melodyFrames = [MelodyFrame]()
        for packet in packets {
            if let frame = packet.melody, melodyFrames.last?.time != frame.time { melodyFrames.append(frame) }
        }
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
