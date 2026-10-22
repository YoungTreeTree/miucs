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
