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
        let failed = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count-failed, "failed": failed, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/singing-pitch-tests.json"))
        if failed > 0 { exit(1) }
    }
}
