import AVFoundation
import Foundation

@main
enum RapidlyFileProbe {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5 else {
            throw AudioAnalysisError.invalidInput("rapidly-file-probe model.rapidly input.wav frames.json statistics.json")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]), commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        let length = Int(file.length), chunk = 512
        let started = ProcessInfo.processInfo.systemUptime
        let license = ProcessInfo.processInfo.environment["MIUCS_RAPIDLY_LICENSE_FILE"].map { URL(fileURLWithPath: $0) }
        let separator = try RapidlyVocalProcessor(configuration: RapidlyConfiguration(
            modelURL: URL(fileURLWithPath: args[1]), licenseFile: license))
        let initializationMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let analyzer = try MelodyAnalyzer()
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var results = [MelodyFrame](), timings = [Double](), separationTimes = [Double]()
        var consumed = 0, produced = 0, firstOutputAt: Double?, firstMelodyAt: Double?
        var deliveryAges = [Double]()
        var flushedSamples = 0
        // Drain the finite file tail for accuracy scoring. These final zero feeds
        // are excluded from runtime metrics and never used by live capture.
        while produced < length {
            let input: [[Float]]
            let flushing = file.framePosition >= file.length
            if !flushing {
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                input = (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
                consumed += Int(buffer.frameLength)
            } else {
                flushedSamples += chunk
                guard Double(flushedSamples) / rate < 2 else { throw RapidlyFailure.output }
                input = .init(repeating: .init(repeating: 0, count: chunk), count: channels)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let output = try separator.process(AudioPCMBlock(channels: input, sampleRate: rate, isInterleaved: false))
            let separatedAt = ProcessInfo.processInfo.systemUptime
            if let output {
                if firstOutputAt == nil { firstOutputAt = Double(consumed) / rate }
                let samples = min(output.channels[0].count, length - produced)
                let pcm = output.channels.map { Array($0.prefix(samples)) }
                produced += samples
                let frames = try analyzer.process(channels: pcm, sampleRate: rate)
                if !frames.isEmpty, firstMelodyAt == nil { firstMelodyAt = Double(consumed) / rate }
                results += frames
                if !flushing { deliveryAges += frames.map { Double(consumed) / rate - $0.time } }
            }
            if !flushing {
                separationTimes.append((separatedAt - start) * 1000)
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        func percentiles(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [:] }
            return ["p50": sorted[Int(Double(sorted.count - 1) * 0.5)],
                    "p95": sorted[Int(Double(sorted.count - 1) * 0.95)], "max": sorted.last!]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: args[3]))
        let stats: [String: Any] = [
            "sampleRate": rate, "channels": channels, "audioSeconds": Double(length) / rate,
            "inputBlockSamples": chunk, "inputBlockMilliseconds": Double(chunk) / rate * 1000,
            "mode": separator.statusDescription, "hasAcceptedOfflineKey": separator.hasAcceptedOfflineKey,
            "maximumModelLatencySeconds": separator.maximumLatencySeconds,
            "outputBusses": separator.busNames, "selectedBus": "vocals",
            "initializationMilliseconds": initializationMS,
            "firstOutputAfterInputSeconds": firstOutputAt ?? -1,
            "firstMelodyAfterInputSeconds": firstMelodyAt ?? -1,
            "separationMilliseconds": percentiles(separationTimes),
            "separationAndMelodyMilliseconds": percentiles(timings),
            "totalProcessingMilliseconds": timings.reduce(0, +),
            "melodyWindowCenterAgeSeconds": percentiles(deliveryAges),
            "scope": "512-sample causal input; excludes file I/O, capture, UI, display and initialization; finite tail flushed only for scoring; demo watermark left intact"
        ]
        try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[4]))
    }
}
