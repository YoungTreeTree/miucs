import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private struct CheckResult: Codable {
    var name: String
    var passed: Bool
    var measurements: [String: Double]
    var detail: String
}

private struct TestReport: Codable {
    var date: String
    var windowSize = AudioFeatureAnalyzer.windowSize
    var hopSize = AudioFeatureAnalyzer.hopSize
    var passed: Int
    var failed: Int
    var checks: [CheckResult]
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

private func close(_ value: Double?, _ expected: Double, tolerance: Double, name: String) throws {
    guard let value, value.isFinite, abs(value - expected) <= tolerance else {
        throw CheckFailure(description: "\(name): \(String(describing: value)), expected \(expected) ± \(tolerance)")
    }
}

private func sine(_ hz: Double, amplitude: Double = 0.5, seconds: Double = 1,
                  rate: Double = 48_000, phase: Double = 0) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate + phase)) }
}

private func noise(seconds: Double, amplitude: Double = 0.2, seed: UInt64 = 42) -> [Float] {
    var state = seed
    return (0..<Int(seconds * 48_000)).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float((Double(state >> 32) / Double(UInt32.max) * 2 - 1) * amplitude)
    }
}

/// Keep the live fixture well inside the output route's passband. The unfiltered
/// white-noise tests above still check full-band flatness and stationary onsets.
private func bandLimitedNoise(seconds: Double, seed: UInt64) -> [Float] {
    let taps = 129, middle = Double(taps - 1) / 2, cutoff = 8_000.0 / 48_000
    var coefficients = (0..<taps).map { i -> Double in
        let x = Double(i) - middle
        let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
        return sinc * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1)))
    }
    let gain = coefficients.reduce(0, +)
    coefficients = coefficients.map { $0 / gain }
    let input = noise(seconds: seconds + Double(taps) / 48_000, amplitude: 0.08, seed: seed)
    return (0..<Int(seconds * 48_000)).map { i in
        var value = 0.0
        for tap in 0..<taps { value += Double(input[i + tap]) * coefficients[tap] }
        return Float(value)
    }
}

private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }

private func analyze(_ channels: [[Float]], rate: Double = 48_000,
                     chunks: [Int] = [480]) throws -> [AudioFeatures] {
    let analyzer = try AudioFeatureAnalyzer()
    var output = [AudioFeatures](), offset = 0, chunkIndex = 0
    while offset < channels[0].count {
        let end = min(offset + chunks[chunkIndex % chunks.count], channels[0].count)
        output += try analyzer.process(channels: channels.map { Array($0[offset..<end]) }, sampleRate: rate)
        offset = end; chunkIndex += 1
    }
    return output
}

private func makePCM(_ channels: [[Float]], interleaved: Bool, rate: Double = 48_000,
                     float: Bool = true) throws -> CMSampleBuffer {
    let channelCount = channels.count, frameCount = channels[0].count
    let bytesPerFrame = UInt32((interleaved ? channelCount : 1) * 4)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(channelCount),
        mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    try require(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    ) == noErr, "Create PCM format")
    var packed = [Float]()
    if interleaved {
        for frame in 0..<frameCount { for channel in channels { packed.append(channel[frame]) } }
    } else { packed = channels.flatMap { $0 } }
    let bytes = packed.count * 4
    var block: CMBlockBuffer?
    try require(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
    ) == noErr, "Create PCM memory")
    let copyStatus = packed.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                      offsetIntoDestination: 0, dataLength: bytes)
    }
    try require(copyStatus == noErr, "Copy PCM memory")
    var buffer: CMSampleBuffer?
    try require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!,
        sampleCount: frameCount, presentationTimeStamp: .zero,
        packetDescriptions: nil, sampleBufferOut: &buffer
    ) == noErr, "Create PCM sample buffer")
    return buffer!
}

private struct FixtureSegment: Codable {
    var name: String
    var start: Double
    var duration: Double
    var frequency: Double?
    var balance: Double?
    var sideEnergyRatio: Double?
    var correlation: Double?
    var expectedRMS: Double
    var band: String?
}

private func writeLiveFixture(_ directory: URL) throws {
    var left = [Float](), right = [Float](), segments = [FixtureSegment]()
    func add(_ name: String, _ l: [Float], _ r: [Float], frequency: Double? = nil,
             balance: Double? = nil, side: Double? = nil, correlation: Double? = nil,
             band: String? = nil) {
        let start = Double(left.count) / 48_000
        let rms = sqrt(zip(l, r).reduce(0.0) { $0 + (Double($1.0) * Double($1.0) + Double($1.1) * Double($1.1)) / 2 } / Double(l.count))
        segments.append(FixtureSegment(name: name, start: start, duration: Double(l.count) / 48_000,
                                       frequency: frequency, balance: balance, sideEnergyRatio: side,
                                       correlation: correlation, expectedRMS: rms, band: band))
        left += l; right += r
    }
    let silence = [Float](repeating: 0, count: 48_000)
    add("silence-start", silence, silence)
    for (name, hz, band) in [("low", 187.5, "low"), ("mid", 1_500.0, "mid"), ("high", 6_000.0, "high")] {
        let tone = sine(hz, amplitude: 0.12, seconds: 1.2)
        add(name, tone, tone, frequency: hz, balance: 0, side: 0, correlation: 1, band: band)
        add("gap-\(name)", Array(silence.prefix(19_200)), Array(silence.prefix(19_200)))
    }
    let tone = sine(1_500, amplitude: 0.12, seconds: 1.2)
    let zero = [Float](repeating: 0, count: tone.count)
    add("left", tone, zero, frequency: 1_500, balance: -1, side: 0.5, band: "mid")
    add("right", zero, tone, frequency: 1_500, balance: 1, side: 0.5, band: "mid")
    add("anti-phase", tone, tone.map { -$0 }, frequency: 1_500, balance: 0,
        side: 1, correlation: -1, band: "mid")
    let n1 = bandLimitedNoise(seconds: 1.2, seed: 42)
    let n2 = bandLimitedNoise(seconds: 1.2, seed: 73)
    add("noise", n1, n2, balance: 0, side: 0.5, correlation: 0)
    add("silence-end", silence, silence)

    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                               channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
    buffer.frameLength = buffer.frameCapacity
    for (channel, values) in [left, right].enumerated() {
        values.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![channel].update(from: ptr.baseAddress!, count: values.count)
        }
    }
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("system-audio-fixture.wav"),
                               settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(segments).write(to: directory.appendingPathComponent("system-audio-fixture.json"))
}

@main
private struct AudioFeatureTests {
    static func main() throws {
        let reportPath = CommandLine.arguments.dropFirst().first ?? "docs/validation/audio-feature-tests.json"
        let reportURL = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var results = [CheckResult]()
        func test(_ name: String, detail: String = "", _ body: () throws -> [String: Double]) {
            do {
                let measurements = try body()
                results.append(CheckResult(name: name, passed: true, measurements: measurements, detail: detail))
                print("PASS \(name)")
            } catch {
                results.append(CheckResult(name: name, passed: false, measurements: [:], detail: String(describing: error)))
                print("FAIL \(name): \(error)")
            }
        }

        test("RMS / peak / crest / dBFS", detail: "0.5-amplitude 1500 Hz sine; RMS=0.5/√2, crest=3.0103 dB") {
            let f = try analyze([sine(1_500)]).last!
            try close(f.rms, 0.5 / sqrt(2), tolerance: 1e-7, name: "RMS")
            try close(f.peak, 0.5, tolerance: 1e-7, name: "Peak")
            try close(f.crestDB, 3.01029996, tolerance: 1e-5, name: "Crest")
            try close(f.rmsDBFS, -9.03089987, tolerance: 1e-5, name: "dBFS")
            return ["rms": f.rms, "peak": f.peak, "crestDB": f.crestDB!, "rmsDBFS": f.rmsDBFS]
        }
        test("Amplitude scaling remains linear") {
            let a = try analyze([sine(1_500, amplitude: 0.5)]).last!
            let b = try analyze([sine(1_500, amplitude: 0.25)]).last!
            let c = try analyze([sine(1_500, amplitude: 1.25)]).last!
            try close(a.rmsDBFS - b.rmsDBFS, 6.02059991, tolerance: 1e-5, name: "Half amplitude")
            try close(c.peak, 1.25, tolerance: 1e-7, name: "Unclamped raw peak")
            return ["halfAmplitudeDB": a.rmsDBFS - b.rmsDBFS, "unclampedPeak": c.peak]
        }
        test("Silence has no fabricated spectral / spatial values") {
            let all = try analyze([Array(repeating: 0, count: 48_000), Array(repeating: 0, count: 48_000)])
            let f = all.last!
            try require(f.rms == 0 && f.peak == 0 && f.isSilent && f.silenceDuration > 0.9, "Silence state")
            try require(f.centroidHz == nil && f.flatness == nil && f.lowShare == nil && f.balance == nil
                        && f.correlation == nil && f.sideEnergyRatio == nil && f.crestDB == nil, "Undefined measurements must be nil")
            try require(all.allSatisfy { !$0.isOnset && $0.rmsDBFS.isFinite && $0.displayBands.allSatisfy { $0 == 0 } }, "Silence output")
            return ["rms": f.rms, "silenceDuration": f.silenceDuration]
        }
        for (name, hz) in [("low", 187.5), ("mid", 1_500.0), ("high", 6_000.0)] {
            test("Single-tone frequency and \(name) band", detail: "Frequency tolerance 2 Hz; band share ≥ 99%") {
                let f = try analyze([sine(hz)]).last!
                try close(f.centroidHz, hz, tolerance: 2, name: "Centroid")
                let share = name == "low" ? f.lowShare! : name == "mid" ? f.midShare! : f.highShare!
                try require(share > 0.99, "Expected \(name) share > 0.99, got \(share)")
                try require(f.bandwidthHz! < 60, "Pure sine bandwidth")
                return ["frequencyHz": f.centroidHz!, "bandShare": share, "bandwidthHz": f.bandwidthHz!]
            }
        }
        test("Mixture band energies follow squared amplitudes", detail: "187.5/1500/6000 Hz at amplitudes 0.3/0.2/0.1; shares 9/14,4/14,1/14") {
            let a = sine(187.5, amplitude: 0.3), b = sine(1_500, amplitude: 0.2), c = sine(6_000, amplitude: 0.1)
            let mixed = a.indices.map { a[$0] + b[$0] + c[$0] }
            let f = try analyze([mixed]).last!
            try close(f.lowShare, 9.0 / 14, tolerance: 1e-4, name: "Low share")
            try close(f.midShare, 4.0 / 14, tolerance: 1e-4, name: "Mid share")
            try close(f.highShare, 1.0 / 14, tolerance: 1e-4, name: "High share")
            try close(f.lowEnergy + f.midEnergy + f.highEnergy, 0.07, tolerance: 1e-5, name: "Total spectral power")
            return ["lowShare": f.lowShare!, "midShare": f.midShare!, "highShare": f.highShare!,
                    "spectralPower": f.lowEnergy + f.midEnergy + f.highEnergy]
        }
        test("Brightness and spectral spread distinguish signals") {
            let low = try analyze([sine(187.5)]).last!, high = try analyze([sine(6_000)]).last!
            let broad = try analyze([noise(seconds: 1)]).last!
            try require(high.centroidHz! > low.centroidHz! * 20, "Brightness ordering")
            try require(broad.bandwidthHz! > high.bandwidthHz! * 20, "Bandwidth ordering")
            return ["lowCentroid": low.centroidHz!, "highCentroid": high.centroidHz!, "noiseBandwidth": broad.bandwidthHz!]
        }
        test("Flatness distinguishes tone and seeded white noise", detail: "Tone < 0.001; mean white-noise power flatness 0.3...0.9") {
            let tone = try analyze([sine(1_500)]).last!
            let ns = try analyze([noise(seconds: 3)])
            let flatness = mean(ns.compactMap(\.flatness))
            try require(tone.flatness! < 0.001 && flatness > 0.3 && flatness < 0.9, "Flatness: tone \(tone.flatness!), noise \(flatness)")
            return ["toneFlatness": tone.flatness!, "noiseFlatness": flatness]
        }
        for (name, leftGain, rightGain, balance, side, corr) in [
            ("left only", 1.0, 0.0, -1.0, 0.5, Optional<Double>.none),
            ("right only", 0.0, 1.0, 1.0, 0.5, nil),
            ("in phase", 1.0, 1.0, 0.0, 0.0, 1.0),
            ("anti phase", 1.0, -1.0, 0.0, 1.0, -1.0)
        ] {
            test("Stereo \(name)") {
                let tone = sine(1_500)
                let f = try analyze([tone.map { $0 * Float(leftGain) }, tone.map { $0 * Float(rightGain) }]).last!
                try close(f.balance, balance, tolerance: 1e-7, name: "Balance")
                try close(f.sideEnergyRatio, side, tolerance: 1e-7, name: "Side energy ratio")
                if let corr { try close(f.correlation, corr, tolerance: 1e-7, name: "Correlation") }
                else { try require(f.correlation == nil, "Correlation undefined for silent channel") }
                try close(f.centroidHz, 1_500, tolerance: 2, name: "Stereo spectrum must not cancel")
                return ["balance": f.balance!, "sideEnergyRatio": f.sideEnergyRatio!, "centroidHz": f.centroidHz!]
            }
        }
        test("Independent stereo noise") {
            let fs = try analyze([noise(seconds: 2, seed: 17), noise(seconds: 2, seed: 101)])
            let correlation = mean(fs.compactMap(\.correlation)), side = mean(fs.compactMap(\.sideEnergyRatio))
            try close(correlation, 0, tolerance: 0.03, name: "Independent correlation")
            try close(side, 0.5, tolerance: 0.02, name: "Independent side ratio")
            return ["correlation": correlation, "sideEnergyRatio": side]
        }
        test("Mono has no stereo measurements") {
            let f = try analyze([sine(1_500)]).last!
            try require(f.balance == nil && f.correlation == nil && f.sideEnergyRatio == nil, "Mono must not fabricate stereo")
            return ["channelCount": Double(f.channelCount)]
        }
        test("DC removal preserves spectrum and centered correlation") {
            let left = sine(1_500).map { $0 + 0.2 }, right = sine(1_500).map { $0 + 0.4 }
            let f = try analyze([left, right]).last!
            try close(f.centroidHz, 1_500, tolerance: 2, name: "DC removed from spectrum")
            try close(f.correlation, 1, tolerance: 1e-6, name: "Centered correlation")
            return ["centroidHz": f.centroidHz!, "correlation": f.correlation!]
        }
        for rate in [44_100.0, 96_000.0] {
            test("Actual sample rate \(Int(rate)) Hz", detail: "1000 Hz non-bin-centered tone, centroid tolerance 10 Hz") {
                let f = try analyze([sine(1_000, rate: rate)], rate: rate).last!
                try close(f.centroidHz, 1_000, tolerance: 10, name: "Sample-rate-aware frequency")
                return ["centroidHz": f.centroidHz!, "sampleRate": f.sampleRate]
            }
        }
        test("Chunk sizes do not change analysis", detail: "Same PCM in 480-sample vs 17/511/4096/127/1024-sample blocks; exact JSON equality") {
            let l = noise(seconds: 1.7), r = sine(1_500, seconds: 1.7)
            let a = try analyze([l, r]), b = try analyze([l, r], chunks: [17, 511, 4096, 127, 1024])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try require(try encoder.encode(a) == encoder.encode(b), "Chunking changed measurements")
            let expected = (l.count - 2048) / 1024 + 1
            try require(a.count == expected, "Missing / duplicated frames")
            return ["frames": Double(a.count), "expectedFrames": Double(expected)]
        }
        test("Sample-rate changes reset pending audio and history") {
            let analyzer = try AudioFeatureAnalyzer()
            _ = try analyzer.process(channels: [sine(1_500, seconds: 0.2)], sampleRate: 48_000)
            let fs = try analyzer.process(channels: [sine(1_000, rate: 44_100)], sampleRate: 44_100)
            try close(fs.first!.time, 1024.0 / 44_100, tolerance: 1e-12, name: "Reset timeline")
            try close(fs.last!.centroidHz, 1_000, tolerance: 10, name: "Reset spectrum")
            return ["firstTime": fs.first!.time, "centroidHz": fs.last!.centroidHz!]
        }
        test("Time-based attack and release", detail: "25 ms attack, 200 ms release; analytic exponential on DC level step") {
            let signal = [Float](repeating: 0.5, count: 24_576) + [Float](repeating: 0, count: 24_576)
            let fs = try analyze([signal])
            try close(fs[0].envelope, 0.5 * (1 - exp(-(2048.0 / 48_000) / 0.025)), tolerance: 1e-7, name: "Attack")
            let silentFrames = fs.filter { $0.rms == 0 }
            let start = silentFrames.first!, end = silentFrames.last!
            let expected = start.envelope * exp(-(end.time - start.time) / 0.2)
            try close(end.envelope, expected, tolerance: 1e-7, name: "Release")
            return ["firstEnvelope": fs[0].envelope, "lastEnvelope": end.envelope, "expectedLastEnvelope": expected]
        }
        test("Silence hysteresis and hold time") {
            func dc(_ db: Double, _ seconds: Double) -> [Float] { Array(repeating: Float(pow(10, db / 20)), count: Int(seconds * 48_000)) }
            let fs = try analyze([dc(-30, 0.4) + dc(-57, 0.4) + dc(-66, 0.4) + dc(-57, 0.4) + dc(-30, 0.4)])
            func at(_ t: Double) -> AudioFeatures { fs.min { abs($0.time - t) < abs($1.time - t) }! }
            try require(!at(0.6).isSilent && at(1.1).isSilent && at(1.4).isSilent && !at(1.8).isSilent, "Hysteresis transitions")
            try require(!at(0.86).isSilent, "Do not enter silence before hold time")
            return ["silenceHoldSeconds": AudioFeatureAnalyzer.silenceHold]
        }
        test("Stationary sine and noise avoid repeated onsets", detail: "Sine: zero events; seeded white noise after first second: zero events in 5 seconds") {
            let tone = try analyze([sine(1_500, seconds: 3)]), ns = try analyze([noise(seconds: 6)])
            let toneCount = tone.filter(\.isOnset).count, noiseCount = ns.filter { $0.time > 1 && $0.isOnset }.count
            try require(toneCount == 0 && noiseCount == 0, "False onsets: tone \(toneCount), noise \(noiseCount)")
            return ["toneFalseOnsets": Double(toneCount), "noiseFalseOnsetsAfterWarmup": Double(noiseCount)]
        }
        test("Known drum-like onsets", detail: "8 decaying low-tone/noise bursts at 0.5-second intervals; match within 50 ms; no extra events") {
            var samples = [Float](repeating: 0, count: 48_000 * 5)
            let eventTimes = (1...8).map { Double($0) * 0.5 }, burstNoise = noise(seconds: 0.08, amplitude: 0.1)
            for time in eventTimes {
                let start = Int(time * 48_000)
                for i in burstNoise.indices {
                    let t = Double(i) / 48_000
                    samples[start + i] += Float((0.6 * sin(2 * .pi * 93.75 * t) + Double(burstNoise[i])) * exp(-t / 0.02))
                }
            }
            let detections = try analyze([samples]).filter(\.isOnset).map(\.time)
            try require(detections.count == eventTimes.count, "Expected 8 onsets, got \(detections)")
            let errors = zip(detections, eventTimes).map { abs($0 - $1) }
            try require(errors.max()! <= 0.05, "Onset error \(errors)")
            return ["detected": Double(detections.count), "maxTimingErrorMs": errors.max()! * 1000]
        }
        for layout in [false, true] {
            test("PCM decoding \(layout ? "interleaved" : "planar")", detail: "CoreMedia sample buffer round-trip, stereo channel identity and rate") {
                let input = [sine(1_500, seconds: 0.1), sine(6_000, amplitude: 0.25, seconds: 0.1)]
                let pcm = try AudioPCMDecoder.decode(makePCM(input, interleaved: layout, rate: 44_100))
                try require(pcm.channels == input && pcm.sampleRate == 44_100 && pcm.isInterleaved == layout, "PCM channel / format mismatch")
                return ["frames": Double(pcm.channels[0].count), "sampleRate": pcm.sampleRate]
            }
        }
        test("Invalid input rejected without poisoning next frame") {
            let analyzer = try AudioFeatureAnalyzer()
            var rejected = 0
            for (channels, rate) in [([[Float.nan]], 48_000.0), ([[Float.infinity]], 48_000), ([[0], [0, 1]], 48_000), ([[0]], 0), ([[0]], Double.nan)] {
                do { _ = try analyzer.process(channels: channels, sampleRate: rate) }
                catch { rejected += 1 }
            }
            try require(rejected == 5, "Reject invalid PCM inputs")
            do {
                _ = try AudioPCMDecoder.decode(makePCM([sine(1_500, seconds: 0.1)], interleaved: true, float: false))
                throw CheckFailure(description: "Accepted integer PCM as float")
            } catch is AudioAnalysisError { rejected += 1 }
            let valid = try analyzer.process(channels: [sine(1_500)], sampleRate: 48_000)
            try close(valid.last!.centroidHz, 1_500, tolerance: 2, name: "Recovery")
            return ["rejectedCases": Double(rejected)]
        }
        test("Streaming throughput", detail: "10 seconds of stereo input; processing faster than real time") {
            let input = [noise(seconds: 10), noise(seconds: 10, seed: 73)]
            let start = ProcessInfo.processInfo.systemUptime
            let frames = try analyze(input)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            try require(elapsed < 10, "Cannot keep up with real-time PCM")
            return ["audioSeconds": 10, "processingSeconds": elapsed, "millisecondsPerFrame": elapsed * 1000 / Double(frames.count)]
        }

        let passed = results.filter(\.passed).count
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = TestReport(date: ISO8601DateFormatter().string(from: Date()), passed: passed,
                                failed: results.count - passed, checks: results)
        try encoder.encode(report).write(to: reportURL)
        try writeLiveFixture(URL(fileURLWithPath: "build", isDirectory: true))
        print("\(passed)/\(results.count) checks passed; report: \(reportURL.path)")
        if passed != results.count { exit(1) }
    }
}
