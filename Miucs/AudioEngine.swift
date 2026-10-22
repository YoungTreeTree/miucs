import CoreMedia
import Foundation
import ScreenCaptureKit

/// Publishes measurements separately from the gain and smoothing of display values.
@MainActor
final class AudioEngine: NSObject, ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var bands: [Float] = Array(repeating: 0, count: AudioFeatureAnalyzer.bandCount)
    @Published private(set) var features: AudioFeatures?
    @Published private(set) var melody: MelodyFrame?
    @Published private(set) var status = "正在连接系统音频…"
    @Published private(set) var isRunning = false

    private var smoother = BandSmoother()
    private var stream: SCStream?
    private var output: StreamOutput?
    private var isStarting = false
    private var generation = UUID()

    func start(excludingExistingApplications: Bool = false) async {
        guard stream == nil, !isStarting else { return }
        let token = UUID()
        generation = token
        isStarting = true
        status = "正在连接系统音频…"
        defer { if generation == token { isStarting = false } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: !excludingExistingApplications
            )
            guard generation == token else { return }
            guard let display = content.displays.first else {
                status = "没有找到显示器"
                return
            }
            // A diagnostic fixture starts afplay AFTER this snapshot. Excluding existing
            // apps isolates it without pausing or changing the user's other players.
            let filter = excludingExistingApplications
                ? SCContentFilter(display: display, excludingApplications: content.applications, exceptingWindows: [])
                : SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true

            let output = try StreamOutput { [weak self] frame, melody in
                Task { @MainActor in
                    guard let self, self.generation == token, self.isRunning else { return }
                    self.features = frame
                    self.melody = melody
                    self.level = Float(min(frame.envelope * 4, 1))
                    self.bands = self.smoother.push(
                        frame.displayBands,
                        dt: Double(AudioFeatureAnalyzer.hopSize) / frame.sampleRate
                    )
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            guard generation == token else {
                try? await stream.stopCapture()
                return
            }
            self.output = output
            self.stream = stream
            status = "正在听系统声音"
            isRunning = true
            Self.trace("capture started")
        } catch {
            guard generation == token else { return }
            status = "无法捕获系统音频：\(error.localizedDescription)"
            isRunning = false
            Self.trace("capture failed: \(error)")
        }
    }

    nonisolated static func trace(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/miucs.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    func stop() {
        generation = UUID()
        isStarting = false
        let stream = stream
        self.stream = nil
        output = nil
        isRunning = false
        features = nil
        melody = nil
        level = 0
        bands = Array(repeating: 0, count: AudioFeatureAnalyzer.bandCount)
        smoother = BandSmoother()
        status = "已暂停"
        Task { try? await stream?.stopCapture() }
    }
}

extension AudioEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedStreamID = ObjectIdentifier(stream)
        Task { @MainActor in
            guard self.stream.map(ObjectIdentifier.init) == stoppedStreamID else { return }
            self.stop()
            self.status = "音频中断：\(error.localizedDescription)"
            AudioEngine.trace("stream stopped: \(error)")
        }
    }
}

/// Each capture owns immutable callbacks and a fresh analyzer, used only on its audio queue.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "miucs.audio", qos: .userInteractive)
    private let onFrame: @Sendable (AudioFeatures, MelodyFrame?) -> Void
    private let analyzer: AudioFeatureAnalyzer
    private let melodyAnalyzer: MelodyAnalyzer
    private var latestMelody: MelodyFrame?
    private var didLogBuffer = false
    private var didLogError = false

    init(onFrame: @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void) throws {
        self.onFrame = onFrame
        analyzer = try AudioFeatureAnalyzer()
        melodyAnalyzer = try MelodyAnalyzer()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        do {
            let block = try AudioPCMDecoder.decode(sampleBuffer)
            let melodies = try melodyAnalyzer.process(channels: block.channels, sampleRate: block.sampleRate)
            if let last = melodies.last { latestMelody = last }
            for frame in try analyzer.process(channels: block.channels, sampleRate: block.sampleRate) {
                onFrame(frame, latestMelody)
            }
            if !didLogBuffer {
                didLogBuffer = true
                AudioEngine.trace(
                    "frames=\(block.channels[0].count) ch=\(block.channels.count) " +
                    "interleaved=\(block.isInterleaved) rate=\(Int(block.sampleRate))"
                )
            }
        } catch {
            if !didLogError {
                didLogError = true
                AudioEngine.trace("analysis failed: \(error)")
            }
        }
    }
}

private struct BandSmoother {
    private var values = [Float](repeating: 0, count: AudioFeatureAnalyzer.bandCount)

    mutating func push(_ raw: [Float], dt: Double) -> [Float] {
        for i in values.indices {
            let target = i < raw.count ? raw[i] : 0
            let tau = target > values[i] ? 0.025 : 0.18
            values[i] += (target - values[i]) * Float(1 - exp(-dt / tau))
        }
        return values
    }
}
