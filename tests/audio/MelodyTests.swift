import Foundation

@main
struct MelodyTests {
    static func main() throws {
        let rate = 48_000.0
        func tone(_ frequency: Double, _ amplitude: Double = 0.2, seconds: Double = 0.6,
                  partials: [Double] = [1]) -> [Float] {
            (0..<Int(seconds * rate)).map { i in
                let t = Double(i) / rate
                return Float(partials.enumerated().reduce(0.0) { $0 + amplitude * $1.element * sin(2 * .pi * frequency * Double($1.offset + 1) * t) })
            }
        }
        func analyze(_ samples: [Float], chunk: Int = 480) throws -> [MelodyFrame] {
            let analyzer = try MelodyAnalyzer()
            var frames = [MelodyFrame]()
            for i in stride(from: 0, to: samples.count, by: chunk) {
                frames += try analyzer.process(channels: [Array(samples[i..<min(i + chunk, samples.count)])], sampleRate: rate)
            }
            return frames
        }
        var results = [[String: Any]]()
        func check(_ name: String, _ body: () throws -> (Bool, [String: Any])) {
            do {
                let (passed, metrics) = try body()
                results.append(["name": name, "passed": passed, "metrics": metrics])
                print("\(passed ? "PASS" : "FAIL") \(name): \(metrics)")
            } catch { results.append(["name": name, "passed": false, "error": String(describing: error)]) }
        }
        for hz in [130.8128, 220, 261.6256, 440, 523.2511, 880, 1046.502] {
            check("Single-note \(hz) Hz") {
                let frames = try analyze(tone(hz))
                let voiced = frames.filter(\.isMelodic)
                let errors = voiced.compactMap { $0.pitchHz.map { abs(1200 * log2($0 / hz)) } }
                let error = errors.max() ?? 9999
                return (voiced.count > frames.count * 9 / 10 && error < 35,
                        ["maxCentsError": error, "voiced": voiced.count, "frames": frames.count])
            }
        }
        let notes = [261.6256, 329.6276, 391.9954, 329.6276, 261.6256, 523.2511, 261.6256]
        for style in ["instrument", "vocal-formants"] {
            check("Predominant melody with accompaniment: \(style)") {
                var audio = [Float]()
                for hz in notes {
                    let partials = style == "instrument" ? [1, 0.5, 0.3, 0.18, 0.12] : (1...10).map { h in
                        0.25 / Double(h) + exp(-pow((hz * Double(h) - 750) / 400, 2)) + 0.6 * exp(-pow((hz * Double(h) - 1_500) / 450, 2))
                    }
                    let melody = tone(hz, 0.16, partials: partials)
                    let bass = tone(110, 0.07, partials: [1, 0.35, 0.2])
                    let chord1 = tone(164.8138, 0.025), chord2 = tone(195.9977, 0.025)
                    audio += melody.indices.map { melody[$0] + bass[$0] + chord1[$0] + chord2[$0] }
                }
                let frames = try analyze(audio)
                var hits = 0, count = 0, octaveErrors = 0
                var estimated = [Double]()
                for (i, hz) in notes.enumerated() {
                    let middle = frames.filter { $0.time > Double(i) * 0.6 + 0.18 && $0.time < Double(i + 1) * 0.6 - 0.10 }
                    estimated.append(middle.compactMap(\.pitchHz).reduce(0, +) / Double(max(middle.compactMap(\.pitchHz).count, 1)))
                    for frame in middle {
                        count += 1
                        if let pitch = frame.pitchHz {
                            let cents = abs(1200 * log2(pitch / hz))
                            if cents < 50 { hits += 1 }
                            if abs(cents - 1200) < 50 { octaveErrors += 1 }
                        }
                    }
                }
                return (Double(hits) / Double(max(count, 1)) >= 0.90,
                        ["accuracyWithin50Cents": Double(hits) / Double(max(count, 1)), "octaveErrors": octaveErrors, "estimatedHz": estimated])
            }
        }
        check("Missing fundamental") {
            let frames = try analyze(tone(220, partials: [0, 1, 0.7, 0.5, 0.3]))
            let hits = frames.filter { $0.pitchHz.map { abs(1200 * log2($0 / 220)) < 50 } ?? false }.count
            return (hits >= frames.count * 9 / 10, ["hits": hits, "frames": frames.count])
        }
        check("Amplitude does not change pitch") {
            let loud = try analyze(tone(329.6276, 0.3, partials: [1, 0.4, 0.2]))
            let quiet = try analyze(tone(329.6276, 0.015, partials: [1, 0.4, 0.2]))
            let same = zip(loud, quiet).allSatisfy { a, b in
                guard let x = a.pitchHz, let y = b.pitchHz else { return a.pitchHz == nil && b.pitchHz == nil }
                return abs(1200 * log2(x / y)) < 15
            }
            return (same, ["comparedFrames": loud.count])
        }
        check("Mixed-spectrum pitch is invariant to gain and polarity") {
            let lead = tone(329.6276, 0.14, partials: [0.25, 1, 0.65, 0.3, 0.2])
            let bass = tone(110, 0.08, partials: [1, 0.4, 0.2])
            let chord = tone(195.9977, 0.035)
            let mixture = lead.indices.map { lead[$0] + bass[$0] + chord[$0] }
            let loud = try analyze(mixture)
            let quiet = try analyze(mixture.map { -$0 * 0.05 })
            let same = zip(loud, quiet).allSatisfy { a, b in
                a.isMelodic == b.isMelodic && abs(a.confidence - b.confidence) < 0.001 &&
                (a.midi.flatMap { x in b.midi.map { abs(x - $0) < 0.15 } } ?? (b.midi == nil))
            }
            return (same && loud.contains(where: \.isMelodic), ["comparedFrames": loud.count])
        }
        check("Melody survives opposite-phase stereo") {
            let samples = tone(220, 0.2, partials: [0.4, 1, 0.5, 0.2])
            let mono = try MelodyAnalyzer().process(channels: [samples], sampleRate: rate)
            let stereo = try MelodyAnalyzer().process(channels: [samples, samples.map { -$0 }], sampleRate: rate)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try encoder.encode(mono) == encoder.encode(stereo), ["frames": mono.count])
        }
        check("Mixed-spectrum melody at 44.1, 48 and 96 kHz") {
            var accuracies = [Double]()
            for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
                let samples = (0..<Int(sampleRate * 0.7)).map { i -> Float in
                    let t = Double(i) / sampleRate
                    let lead = [0.25, 1.0, 0.65, 0.3, 0.2].enumerated().reduce(0.0) {
                        $0 + 0.14 * $1.element * sin(2 * .pi * 329.6276 * Double($1.offset + 1) * t)
                    }
                    return Float(lead + 0.08 * sin(2 * .pi * 110 * t) + 0.035 * sin(2 * .pi * 195.9977 * t))
                }
                let frames = try MelodyAnalyzer().process(channels: [samples], sampleRate: sampleRate)
                let hits = frames.filter { $0.pitchHz.map { abs(1200 * log2($0 / 329.6276)) < 35 } ?? false }.count
                accuracies.append(Double(hits) / Double(max(frames.count, 1)))
            }
            return (accuracies.allSatisfy { $0 >= 0.95 }, ["accuracyWithin35Cents": accuracies])
        }
        check("Silence and broadband percussion reject melody") {
            var state: UInt64 = 123
            let noise = (0..<Int(rate * 3)).map { i -> Float in
                state = state &* 6364136223846793005 &+ 1
                let v = Double(state >> 32) / Double(UInt32.max) * 2 - 1
                let t = Double(i) / rate
                return Float(v * 0.15 * exp(-(t.truncatingRemainder(dividingBy: 0.4)) / 0.08))
            }
            let silent = try analyze([Float](repeating: 0, count: 48_000))
            let ns = try analyze(noise), falseFrames = ns.filter(\.isMelodic).count
            return (silent.allSatisfy { !$0.isMelodic && $0.pitchHz == nil } && falseFrames == 0,
                    ["percussionFalseFrames": falseFrames, "percussionFrames": ns.count])
        }
        check("Chunk-independent pitch timeline") {
            let input = tone(440, seconds: 1)
            let a = try analyze(input, chunk: 480), b = try analyze(input, chunk: 7913)
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            return (try e.encode(a) == e.encode(b), ["frames": a.count])
        }
        check("Causal pitch response measured at PCM delivery, not window center") {
            var delays = [Double]()
            for (before, after) in [(261.6256, 523.2511), (523.2511, 261.6256), (220.0, 329.6276)] {
                let input = tone(before, seconds: 1) + tone(after, seconds: 0.4)
                let analyzer = try MelodyAnalyzer()
                var first: Double?
                for offset in stride(from: 0, to: input.count, by: 480) {
                    let end = min(offset + 480, input.count)
                    let frames = try analyzer.process(channels: [Array(input[offset..<end])], sampleRate: rate)
                    if end > Int(rate), first == nil, frames.contains(where: { frame in
                        frame.isMelodic && frame.pitchHz.map { abs(1200 * log2($0 / after)) < 35 } == true
                    }) { first = Double(end) / rate - 1 }
                }
                delays.append((first ?? 999) * 1000)
            }
            return (delays.allSatisfy { $0 <= 100 }, ["responseMilliseconds": delays, "chunkMilliseconds": 10, "windowSamples": MelodyAnalyzer.windowSize, "hopSamples": MelodyAnalyzer.hopSize])
        }
        let failures = results.filter { !($0["passed"] as! Bool) }.count
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "passed": results.count - failures,
                                    "failed": failures, "checks": results,
                                    "limitations": ["Accompaniment tests are controlled synthesis; not a general-music accuracy guarantee"]]
        try FileManager.default.createDirectory(atPath: "docs/validation", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/melody-tests.json"))
        if failures > 0 { exit(1) }
    }
}
