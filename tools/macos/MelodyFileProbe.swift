import AVFoundation
import Foundation

@main
struct MelodyFileProbe {
    static func main() throws {
        guard (3...4).contains(CommandLine.arguments.count) else { throw AudioAnalysisError.invalidInput("melody-file-probe input-audio output.json [statistics.json]") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]), commonFormat: .pcmFormatFloat32, interleaved: false)
        // One hop per call makes the optional timings actual per-frame analysis
        // costs, rather than the average of a multi-frame batch. PCM delivery
        // latency and rendering costs are measured separately by their tests.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(MelodyAnalyzer.hopSize))!
        let analyzer = try MelodyAnalyzer()
        var frames = [MelodyFrame]()
        var analysisMilliseconds = [Double]()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = (0..<Int(buffer.format.channelCount)).map {
                Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
            }
            let start = ProcessInfo.processInfo.systemUptime
            let next = try analyzer.process(channels: channels, sampleRate: file.processingFormat.sampleRate)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if !next.isEmpty { analysisMilliseconds.append(elapsed) }
            frames += next
        }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(frames).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if CommandLine.arguments.count == 4 {
            let sorted = analysisMilliseconds.sorted()
            func percentile(_ fraction: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)]
            }
            let statistics: [String: Any] = [
                "frames": frames.count,
                "sampleRate": file.processingFormat.sampleRate,
                "audioSeconds": Double(file.length) / file.processingFormat.sampleRate,
                "analysisMillisecondsP50": percentile(0.50),
                "analysisMillisecondsP95": percentile(0.95),
                "analysisMillisecondsMax": sorted.last ?? 0,
                "scope": "MelodyAnalyzer.process on one-hop PCM blocks; excludes file decoding, capture, UI and display latency"
            ]
            try JSONSerialization.data(withJSONObject: statistics, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        }
    }
}
