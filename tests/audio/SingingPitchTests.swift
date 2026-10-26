import Foundation

private final class PitchFixture: SingingPitchPredicting {
    var predictions = 0
    func predict(_ samples: [Float]) throws -> SingingPitchEstimate {
        predictions += 1
        return SingingPitchEstimate(pitchHz: 440, periodicity: 0.95)
    }
}

@main
enum SingingPitchTests {
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        let high = SingingPitchEstimate(pitchHz: 440, periodicity: 0.9)
        let low = SingingPitchEstimate(pitchHz: 440, periodicity: 0.2)
        var gate = SingingVoicingGate()
        let first = gate.receive(estimate: high, rms: 0.1, time: 0)
        let second = gate.receive(estimate: high, rms: 0.1, time: 0.02)
        check("Voicing starts only after two consecutive supported observations", !first && second)
        check("Low reliability ends voicing immediately instead of holding a pitch", !gate.receive(estimate: low, rms: 0.1, time: 0.04))
        let rebound = gate.receive(estimate: high, rms: 0.1, time: 0.06)
        check("One isolated reliable spike cannot restart a note", !rebound)
        _ = gate.receive(estimate: high, rms: 0.1, time: 0.08)
        check("Quiet audio defeats even a confident prediction", !gate.receive(estimate: high, rms: 0.00001, time: 0.10))
        _ = gate.receive(estimate: high, rms: 0.1, time: 0.12)
        check("Long input gaps do not complete an old pending onset", !gate.receive(estimate: high, rms: 0.1, time: 1))
        check("Invalid pitch and reliability never enter the voiced state",
              !gate.receive(estimate: SingingPitchEstimate(pitchHz: .nan, periodicity: 1), rms: 1, time: 1.02) &&
              !gate.receive(estimate: SingingPitchEstimate(pitchHz: 440, periodicity: .nan), rms: 1, time: 1.04))

        func tone(_ rate: Double, hz: Double = 440, duration: Double = 0.3) -> [Float] {
            (0..<Int(rate * duration)).map { Float(0.1 * sin(2 * .pi * hz * Double($0) / rate)) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var invariant = true, timeline = true
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let pcm = tone(rate)
            let one = SingingPitchAnalyzer(predictor: PitchFixture())
            let split = SingingPitchAnalyzer(predictor: PitchFixture())
            let expected = try one.process(channels: [pcm, pcm], sampleRate: rate)
            var actual = [MelodyFrame](), offset = 0, i = 0
            let sizes = [127, 512, 960, 3001, 64]
            while offset < pcm.count {
                let end = min(pcm.count, offset + sizes[i % sizes.count]); i += 1
                let block = Array(pcm[offset..<end]); offset = end
                actual += try split.process(channels: [block, block], sampleRate: rate)
            }
            let actualData = try encoder.encode(actual), expectedData = try encoder.encode(expected)
            invariant = invariant && actualData == expectedData
            timeline = timeline && expected.count > 8 && expected[0].time == 0.032 &&
                expected[1].time == 0.052 && !expected[0].isMelodic && expected[1].isMelodic
        }
        check("Capture block sizes do not change results at 8/16/44.1/48/96/192kHz", invariant)
        check("64ms model windows retain original sample timestamps and a 20ms hop", timeline)

        let resampler = StreamingMonoResampler()
        let lowTone = resampler.process(channels: [tone(48_000, hz: 440)], sampleRate: 48_000)
        resampler.reset()
        let aliased = resampler.process(channels: [tone(48_000, hz: 12_000)], sampleRate: 48_000)
        func rms(_ x: [Float]) -> Double { sqrt(x.dropFirst(100).reduce(0) { $0 + Double($1 * $1) } / Double(x.count - 100)) }
        check("Resampling preserves vocal energy and rejects frequencies above the model Nyquist limit",
              abs(rms(lowTone) - 0.07071) < 0.002 && rms(aliased) < 0.001)
        let fixture = PitchFixture(), analyzer = SingingPitchAnalyzer(predictor: fixture)
        let silence = try analyzer.process(channels: [[Float](repeating: 0, count: 48_000)], sampleRate: 48_000)
        check("Silence never enters neural inference and always publishes absent pitch", fixture.predictions == 0 &&
              silence.allSatisfy { !$0.isMelodic && $0.pitchHz == nil && $0.estimator == .crepe })
        let input = tone(48_000)
        _ = try analyzer.process(channels: [input], sampleRate: 48_000)
        let quieter = try analyzer.process(channels: [[Float](repeating: 0, count: 12_000)], sampleRate: 48_000)
        check("A formerly voiced signal releases after the analysis window drains", quieter.suffix(5).allSatisfy { !$0.isMelodic && $0.pitchHz == nil })
        let changed = try analyzer.process(channels: [Array(tone(44_100).prefix(512))], sampleRate: 44_100)
        check("Format changes discard both resampler history and voicing state", changed.isEmpty)
        let calls = fixture.predictions
        var rejected = false
        do { _ = try analyzer.process(channels: [[.nan]], sampleRate: 44_100) } catch { rejected = true }
        check("Nonfinite PCM is rejected before the model", rejected && fixture.predictions == calls)
        analyzer.reset()
        let reset = try analyzer.process(channels: [input], sampleRate: 48_000)
        check("Reset starts a fresh timeline with no previously confirmed onset", reset[0].time == 0.032 && !reset[0].isMelodic)

        var relative = SingingVoicingGate(usesMixtureReference: true)
        let modest = SingingPitchEstimate(pitchHz: 440, periodicity: 0.45)
        let relativeFirst = relative.receive(estimate: modest, rms: 0.05, time: 0, mixtureRMS: 0.1)
        let relativeSecond = relative.receive(estimate: modest, rms: 0.05, time: 0.02, mixtureRMS: 0.1)
        check("An independently audible vocal can enter with lower periodicity, still requiring two frames", !relativeFirst && relativeSecond)
        check("Confident but weak separator residue releases immediately",
              !relative.receive(estimate: high, rms: 0.01, time: 0.04, mixtureRMS: 0.1))
        check("Missing, silent and nonfinite mix references fail closed",
              !relative.acceptsEnergy(rms: 0.1, mixtureRMS: nil) &&
              !relative.acceptsEnergy(rms: 0.1, mixtureRMS: 0) &&
              !relative.acceptsEnergy(rms: 0.1, mixtureRMS: .nan))
        check("Relative energy decisions are unchanged by common playback gain",
              [0.1, 0.5, 1.0].allSatisfy { gain in
                  relative.acceptsEnergy(rms: gain * 0.05, mixtureRMS: gain * 0.1) &&
                  !relative.acceptsEnergy(rms: gain * 0.01, mixtureRMS: gain * 0.1)
              })

        var aligned = true, gainInvariant = true
        for rate in [16_000.0, 44_100, 48_000, 96_000] {
            let signal = tone(rate, duration: 0.6)
            let mixture = signal.enumerated().map { $0.offset < Int(rate * 0.25) ? $0.element : $0.element * 8 }
            let vocal = signal.map { $0 * 0.5 }
            func run(delayed: Bool, gain: Float = 1) throws -> [MelodyFrame] {
                let a = SingingPitchAnalyzer(predictor: PitchFixture(), usesMixtureReference: true)
                if delayed { try a.receiveMixture(channels: [mixture.map { $0 * gain }], sampleRate: rate) }
                var output = [MelodyFrame]()
                for start in stride(from: 0, to: signal.count, by: 511) {
                    let end = min(start + 511, signal.count)
                    if !delayed { try a.receiveMixture(channels: [mixture[start..<end].map { $0 * gain }], sampleRate: rate) }
                    output += try a.process(channels: [vocal[start..<end].map { $0 * gain }], sampleRate: rate)
                }
                return output
            }
            let live = try run(delayed: false), delayed = try run(delayed: true), quiet = try run(delayed: true, gain: 0.1)
            let liveData = try encoder.encode(live), delayedData = try encoder.encode(delayed), quietData = try encoder.encode(quiet)
            aligned = aligned && liveData == delayedData && live.contains { $0.time < 0.2 && $0.isMelodic } &&
                live.filter { $0.time > 0.35 }.allSatisfy { !$0.isMelodic }
            gainInvariant = gainInvariant && liveData == quietData
        }
        check("Delayed vocals use the matching 64ms mix window at 16/44.1/48/96kHz", aligned)
        check("Playback gain changes preserve relative-gated frame decisions", gainInvariant)

        let requiredFixture = PitchFixture()
        let referenced = SingingPitchAnalyzer(predictor: requiredFixture, usesMixtureReference: true)
        let absent = try referenced.process(channels: [input], sampleRate: 48_000)
        check("Missing reference skips inference instead of inventing relative energy",
              requiredFixture.predictions == 0 && absent.allSatisfy { !$0.isMelodic })
        referenced.reset()
        try referenced.receiveMixture(channels: [tone(48_000, duration: 3)], sampleRate: 48_000)
        let expired = try referenced.process(channels: [input], sampleRate: 48_000)
        check("Stalled separation retains at most two seconds of references and rejects expired windows",
              referenced.bufferedReferenceFrames <= SingingPitchAnalyzer.maximumReferenceFrames &&
              expired.allSatisfy { !$0.isMelodic } && requiredFixture.predictions == 0)
        referenced.reset()
        try referenced.receiveMixture(channels: [input], sampleRate: 48_000)
        let recoveredReference = try referenced.process(channels: [input], sampleRate: 48_000)
        check("Reset restarts both reference and vocal sample clocks together",
              recoveredReference[0].time == 0.032 && !recoveredReference[0].isMelodic && recoveredReference[1].isMelodic)
        referenced.reset()
        let noReplay = try referenced.process(channels: [input], sampleRate: 48_000)
        check("Reset cannot reuse an old mixture reference", noReplay.allSatisfy { !$0.isMelodic })
        try referenced.receiveMixture(channels: [input], sampleRate: 48_000)
        let newRate = tone(44_100)
        try referenced.receiveMixture(channels: [newRate], sampleRate: 44_100)
        let newFormat = try referenced.process(channels: [newRate], sampleRate: 44_100)
        check("Format changes reset both reference and vocal framing before new samples",
              newFormat[0].time == 0.032 && !newFormat[0].isMelodic && newFormat[1].isMelodic)
        let failed = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count-failed, "failed": failed, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/singing-pitch-tests.json"))
        if failed > 0 { exit(1) }
    }
}
