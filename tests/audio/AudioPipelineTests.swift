import Foundation

private final class TestVocalProcessor: VocalPCMProcessor {
    var resets = 0, samples = 0
    var buffering = false, failNext = false
    func reset() { resets += 1; samples = 0 }
    func process(_ block: AudioPCMBlock) throws -> AudioPCMBlock? {
        if failNext { failNext = false; throw AudioAnalysisError.invalidInput("test separator failure") }
        if buffering { return nil }
        let count = block.channels[0].count
        let output = (0..<count).map { Float(0.2 * sin(2 * .pi * 880 * Double($0 + samples) / block.sampleRate)) }
        samples += count
        return AudioPCMBlock(channels: [output], sampleRate: block.sampleRate, isInterleaved: false)
    }
}

private final class FailingMelody: MelodyEstimating {
    var calls = 0
    func reset() {}
    func process(channels: [[Float]], sampleRate: Double) throws -> [MelodyFrame] {
        calls += 1
        throw AudioAnalysisError.invalidInput("test inference failure")
    }
}

@main
enum AudioPipelineTests {
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ value: Bool) {
            checks.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func tone(_ count: Int, rate: Double = 48_000, offset: Int = 0) -> [Float] {
            (0..<count).map { Float(0.2 * sin(2 * .pi * 440 * Double($0 + offset) / rate)) }
        }
        let pipeline = try AudioAnalysisPipeline()
        let features = try AudioFeatureAnalyzer(), melody = try MelodyAnalyzer()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var latest: MelodyFrame?, matched = true, total = 0, offset = 0
        for count in [256, 512, 2048, 1536, 4096, 1000, 8000] {
            let channel = tone(count, offset: offset); offset += count
            let block = AudioPCMBlock(channels: [channel, channel], sampleRate: 48_000, isInterleaved: false)
            if let last = try melody.process(channels: block.channels, sampleRate: block.sampleRate).last { latest = last }
            let expected = try features.process(channels: block.channels, sampleRate: block.sampleRate)
            let actual = try pipeline.process(block)
            matched = matched && expected.count == actual.count
            for (frame, reference) in zip(actual, expected) {
                let actualAudio = try encoder.encode(frame.audio), expectedAudio = try encoder.encode(reference)
                let actualMelody = try encoder.encode(frame.melody), expectedMelody = try encoder.encode(latest)
                matched = matched && actualAudio == expectedAudio && actualMelody == expectedMelody
                total += 1
            }
        }
        check("Shared pipeline preserves all measurements and per-block melody pairing", matched && total > 10)

        let changed = try pipeline.process(AudioPCMBlock(channels: [tone(2048, rate: 44_100)], sampleRate: 44_100, isInterleaved: false))
        check("Format change drops the previous melody until a complete new window arrives",
            changed.count == 1 && changed[0].melody == nil && changed[0].audio.sampleRate == 44_100 && changed[0].audio.channelCount == 1)
        let invalidRejected: Bool
        do {
            _ = try pipeline.process(AudioPCMBlock(channels: [], sampleRate: 0, isInterleaved: false)); invalidRejected = false
        } catch { invalidRejected = true }
        let restored = try pipeline.process(AudioPCMBlock(channels: [tone(4096, rate: 44_100, offset: 2048)], sampleRate: 44_100, isInterleaved: false))
        check("Invalid PCM is rejected without poisoning the next valid analysis block", invalidRejected &&
            !restored.isEmpty && restored.last?.melody?.isMelodic == true)

        let vocal = TestVocalProcessor()
        let separated = try AudioAnalysisPipeline(features: AudioFeatureAnalyzer(), melody: MelodyAnalyzer(), vocals: vocal)
        let raw = try AudioFeatureAnalyzer()
        let input = AudioPCMBlock(channels: [tone(8192), tone(8192)], sampleRate: 48_000, isInterleaved: false)
        let isolated = try separated.process(input)
        let rawFrames = try raw.process(channels: input.channels, sampleRate: input.sampleRate)
        let rawJSON = try encoder.encode(rawFrames), isolatedJSON = try encoder.encode(isolated.map(\.audio))
        check("Only melody uses vocal PCM; level, onset and stereo measurements remain bit-identical",
              rawJSON == isolatedJSON && abs((isolated.last?.melody?.pitchHz ?? 0) - 880) < 5)
        let switched = try separated.process(AudioPCMBlock(channels: [tone(4096, rate: 44_100)], sampleRate: 44_100, isInterleaved: false))
        check("Format changes reset both separation state and the melody timeline",
              vocal.resets == 2 && abs((switched.last?.melody?.time ?? -1) - 2048 / 44_100) < 1e-9)

        let waiting = TestVocalProcessor(); waiting.buffering = true
        let buffering = try AudioAnalysisPipeline(features: AudioFeatureAnalyzer(), melody: MelodyAnalyzer(), vocals: waiting)
        let buffered = try buffering.process(input)
        check("Separation warm-up publishes raw features without substituting accompaniment pitch",
              !buffered.isEmpty && buffered.allSatisfy { $0.melody == nil })

        let failing = TestVocalProcessor()
        var failureCount = 0
        let fallback = try AudioAnalysisPipeline(features: AudioFeatureAnalyzer(), melody: MelodyAnalyzer(), vocals: failing,
                                                onVocalFailure: { _ in failureCount += 1 })
        _ = try fallback.process(input)
        failing.failNext = true
        let small = AudioPCMBlock(channels: [tone(512), tone(512)], sampleRate: 48_000, isInterleaved: false)
        _ = try fallback.process(small)
        let recovered = try fallback.process(input)
        check("Separator failure keeps capture running, clears old melody and falls back at the original PCM time",
              failureCount == 1 && abs((recovered.last?.melody?.pitchHz ?? 0) - 440) < 5 &&
              (recovered.last?.melody?.time ?? 0) > Double(8192) / 48_000)

        let sampleCount = vocal.samples
        do { _ = try separated.process(AudioPCMBlock(channels: [[.nan]], sampleRate: 48_000, isInterleaved: false)) } catch {}
        check("Invalid PCM never enters or resets the native separator", vocal.samples == sampleCount && vocal.resets == 2)

        let required = TestVocalProcessor()
        var suspendedFailures = 0
        let protected = try AudioAnalysisPipeline(features: AudioFeatureAnalyzer(), melody: MelodyAnalyzer(),
            vocals: required, requiresVocalInput: true, onVocalFailure: { _ in suspendedFailures += 1 })
        _ = try protected.process(input)
        required.failNext = true
        let suspended = try protected.process(input)
        let stillSuspended = try protected.process(input)
        check("Singing mode fails closed instead of identifying the accompaniment after separation fails",
              suspendedFailures == 1 && !suspended.isEmpty && suspended.allSatisfy { $0.melody == nil } &&
              stillSuspended.allSatisfy { $0.melody == nil })
        let unavailable = try AudioAnalysisPipeline(features: AudioFeatureAnalyzer(), melody: MelodyAnalyzer(), requiresVocalInput: true)
        let noModel = try unavailable.process(input)
        check("Missing vocal/model resources keep raw audio features alive without guessed notes",
              !noModel.isEmpty && noModel.allSatisfy { $0.melody == nil && !$0.audio.isSilent })
        let failingModel = FailingMelody()
        var modelFailures = 0
        let safeModel = try AudioAnalysisPipeline(features: AudioFeatureAnalyzer(), melody: failingModel,
            vocals: TestVocalProcessor(), requiresVocalInput: true, onMelodyFailure: { _ in modelFailures += 1 })
        let afterFailure = try safeModel.process(input)
        _ = try safeModel.process(input)
        check("Neural inference failure suspends notes once without interrupting audio measurements",
              modelFailures == 1 && failingModel.calls == 1 && !afterFailure.isEmpty && afterFailure.allSatisfy { $0.melody == nil })
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/audio-pipeline-tests.json"))
        if failures > 0 { exit(1) }
    }
}
