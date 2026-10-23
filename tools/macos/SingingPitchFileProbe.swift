import AVFoundation
import Foundation

/// Uses the production resampler, Core ML adapter and voicing gate. The old
/// spectral estimator receives the exact same separated samples for a paired test.
@main
enum SingingPitchFileProbe {
    static func main() throws {
        let args = CommandLine.arguments
        guard (5...6).contains(args.count) else {
            throw AudioAnalysisError.invalidInput("singing-pitch-probe pitch.mlmodelc input.wav frames.json stats.json [separator.rapidly]")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]), commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        let length = Int(file.length), chunk = 512
        let began = ProcessInfo.processInfo.systemUptime
        let predictor = try CoreMLSingingPitch(modelURL: URL(fileURLWithPath: args[1]))
        let analyzer = SingingPitchAnalyzer(predictor: predictor), previous = try MelodyAnalyzer()
        let features = try AudioFeatureAnalyzer()
        let separator: RapidlyVocalProcessor? = args.count == 6 ? try RapidlyVocalProcessor(configuration:
            RapidlyConfiguration(modelURL: URL(fileURLWithPath: args[5]), licenseFile: nil)) : nil
        let initializationMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var results = [MelodyFrame](), baseline = [MelodyFrame](), timings = [Double](), predictionTimes = [Double]()
        var consumed = 0, produced = 0, flushed = 0
        var firstOutputAt: Double?, firstPitchAt: Double?, ages = [Double]()
        while produced < length {
            let input: [[Float]], flushing = file.framePosition >= file.length
            if !flushing {
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                input = (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
                consumed += Int(buffer.frameLength)
            } else {
                guard separator != nil else { break }
                flushed += chunk
                guard Double(flushed) / rate < 2 else { throw RapidlyFailure.output }
                input = .init(repeating: .init(repeating: 0, count: chunk), count: channels)
            }
            let begin = ProcessInfo.processInfo.systemUptime
            _ = try features.process(channels: input, sampleRate: rate)
            let block = AudioPCMBlock(channels: input, sampleRate: rate, isInterleaved: false)
            let output: AudioPCMBlock?
            if let separator { output = try separator.process(block) }
            else { output = block }
            let predictionStart = ProcessInfo.processInfo.systemUptime
            var pcm: [[Float]]?
            if let output {
                if firstOutputAt == nil { firstOutputAt = Double(consumed) / rate }
                let count = min(output.channels[0].count, length - produced)
                pcm = output.channels.map { Array($0.prefix(count)) }
                produced += count
                let frames = try analyzer.process(channels: pcm!, sampleRate: rate)
                if !frames.isEmpty, firstPitchAt == nil { firstPitchAt = Double(consumed) / rate }
                results += frames
                if !flushing { ages += frames.map { Double(consumed) / rate - $0.time } }
            }
            let ended = ProcessInfo.processInfo.systemUptime
            if !flushing {
                timings.append((ended - begin) * 1000)
                predictionTimes.append((ended - predictionStart) * 1000)
            }
            // Baseline computation is outside the production timing measurement.
            if let pcm { baseline += try previous.process(channels: pcm, sampleRate: rate) }
        }
        func percentiles(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [:] }
            return ["p50": sorted[Int(Double(sorted.count - 1) * 0.5)],
                    "p95": sorted[Int(Double(sorted.count - 1) * 0.95)], "max": sorted.last!]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: args[3]))
        try encoder.encode(baseline).write(to: URL(fileURLWithPath: args[3] + ".spectral.json"))
        let stats: [String: Any] = ["model": "CREPE tiny", "sampleRate": rate,
            "mode": separator?.statusDescription ?? "Already separated PCM (paired comparison)",
            "audioSeconds": Double(length) / rate, "initializationMilliseconds": initializationMS,
            "firstOutputAfterInputSeconds": firstOutputAt ?? -1, "firstPitchAfterInputSeconds": firstPitchAt ?? -1,
            "totalAnalysisMilliseconds": percentiles(timings), "pitchMilliseconds": percentiles(predictionTimes),
            "processingMilliseconds": timings.reduce(0, +), "windowCenterAgeSeconds": percentiles(ages),
            "scope": "512-sample causal feed; raw features + optional separation + native neural pitch; excludes file I/O, baseline computation, capture, UI and initialization. Finite separator tail flushed only for scoring."]
        try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[4]))
    }
}
