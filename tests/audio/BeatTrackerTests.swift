import Foundation

@main
enum BeatTrackerTests {
    static func main() throws {
        var checks = [[String: Any]](), results = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func pulses(bpm: Double, rate: Double, offbeats: Bool = false, quiet: Bool = false) throws -> [AudioFeatures] {
            let analyzer = try AudioFeatureAnalyzer()
            let period = 60 / bpm, origin = 0.37
            var frames = [AudioFeatures]()
            for start in stride(from: 0, to: Int(rate * 16), by: 960) {
                let count = min(960, Int(rate * 16) - start)
                let pcm = (0..<count).map { i -> Float in
                    let t = Double(start + i) / rate
                    let age = (t - origin).truncatingRemainder(dividingBy: period)
                    var sound = quiet ? 0 : 0.025 * sin(2 * .pi * 220 * t)
                    if t >= origin, age < 0.08 { sound += 0.5 * exp(-age / 0.018) * sin(2 * .pi * 95 * age) }
                    if offbeats, t >= origin + period / 2 {
                        let off = (t - origin - period / 2).truncatingRemainder(dividingBy: period)
                        if off < 0.04 { sound += 0.09 * exp(-off / 0.009) * sin(2 * .pi * 2400 * off) }
                    }
                    return Float(sound)
                }
                frames += try analyzer.process(channels: [pcm], sampleRate: rate)
            }
            return frames
        }
        for rate in [44_100.0, 48_000] {
            for bpm in [50.0, 60, 90, 120, 150, 180, 200] {
                let frames = try pulses(bpm: bpm, rate: rate)
                let late = frames.compactMap(\.beat).filter { $0.time > 6 }
                let beats = late.compactMap(\.beatTime)
                let errors = beats.map { t in abs((t - 0.37) - ((t - 0.37) / (60 / bpm)).rounded() * (60 / bpm)) }.sorted()
                let tempos = late.compactMap(\.bpm).sorted()
                let medianBPM = tempos.isEmpty ? 0 : tempos[tempos.count / 2]
                let p95 = errors.isEmpty ? 999 : errors[min(errors.count - 1, Int(Double(errors.count) * 0.95))]
                let expected = 10 / (60 / bpm)
                let passed = abs(medianBPM - bpm) < 3 && abs(Double(beats.count) - expected) <= 2 && p95 < 0.07
                check("\(Int(rate))Hz \(Int(bpm))BPM pulse timing and rate", passed)
                results.append(["sampleRate": rate, "targetBPM": bpm, "medianBPM": medianBPM,
                    "pulsesAfter6s": beats.count, "phaseErrorP95Milliseconds": p95 * 1000,
                    "firstBeatSeconds": frames.compactMap { $0.beat?.beatTime }.first ?? -1])
            }
        }
        for (label, offbeat, quiet) in [("Weak subdivisions", true, false), ("Quiet spaces between kicks", false, true)] {
            let frames = try pulses(bpm: 120, rate: 48_000, offbeats: offbeat, quiet: quiet)
            let pulses = frames.compactMap(\.beat).filter { $0.time > 6 && $0.beatTime != nil }
            check("\(label) retain quarter-note pulse", pulses.count >= 17 && pulses.count <= 22 && pulses.allSatisfy { abs(($0.bpm ?? 0) - 120) < 3 })
        }
        var tracker = BeatTracker(), duplicateIgnored = true
        var detected = [BeatFrame]()
        for i in 0..<1000 {
            let t = Double(i) * 0.02, flux = i % 25 == 0 ? 0.9 : 0.01
            if let frame = tracker.process(time: t, flux: flux, lowEnergy: 0.001, silent: false) { detected.append(frame) }
            duplicateIgnored = duplicateIgnored && tracker.process(time: t, flux: flux, lowEnergy: 0.001, silent: false) == nil
        }
        check("Repeated timestamps never advance the pulse clock", duplicateIgnored && detected.contains { $0.beatTime != nil })
        let silence = tracker.process(time: 20, flux: 0, lowEnergy: 0, silent: true)
        check("Silence immediately suppresses pulse output", silence?.beatTime == nil && silence?.bpm == nil)
        let stalled = tracker.process(time: 23, flux: 0.9, lowEnergy: 0.01, silent: false)
        check("Stalls do not replay old pulses or preserve a stale tempo", stalled?.beatTime == nil && stalled?.bpm == nil)
        tracker.reset()
        var falseBeats = 0
        for i in 0..<1000 {
            let f = tracker.process(time: Double(i) * 0.02, flux: 0.02, lowEnergy: 0.001, silent: false)
            if f?.beatTime != nil { falseBeats += 1 }
        }
        check("Steady sound does not invent a metronome", falseBeats == 0)
        check("Invalid numerical input clears tracking safely", tracker.process(time: .nan, flux: .nan, lowEnergy: 0, silent: false) == nil)
        tracker.reset()
        var random: UInt64 = 42, irregularBeats = 0
        for i in 0..<1500 {
            random = random &* 6364136223846793005 &+ 1
            let flux = Double(random >> 32) / Double(UInt32.max)
            if tracker.process(time: Double(i) * 0.02, flux: flux, lowEnergy: 0.001, silent: false)?.beatTime != nil { irregularBeats += 1 }
        }
        check("Uncorrelated attacks do not create a persistent beat clock", irregularBeats == 0)
        print("Uncorrelated attack pulses: \(irregularBeats)")
        tracker.reset()
        var changedTempos = [Double](), afterStop = 0
        for i in 0..<2000 {
            let t = Double(i) * 0.02
            let flux = t < 12 ? (i % 25 == 0 ? 0.9 : 0.01) : (t < 30 && (i - 600) % 20 == 0 ? 0.9 : 0.01)
            let f = tracker.process(time: t, flux: flux, lowEnergy: 0.001, silent: false)
            if t > 23, t < 30, let bpm = f?.bpm { changedTempos.append(bpm) }
            if t > 32, f?.beatTime != nil { afterStop += 1 }
        }
        check("A real tempo change relearns from 120 to 150 BPM", !changedTempos.isEmpty && changedTempos.allSatisfy { abs($0 - 150) < 3 })
        check("A sustained sound after rhythm stops does not keep coasting", afterStop == 0)
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures,
            "checks": checks, "syntheticTiming": results], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/beat-tracker-tests.json"))
        for result in results { print(result) }
        if failures > 0 { exit(1) }
    }
}
