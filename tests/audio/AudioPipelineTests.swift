import Foundation

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
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/audio-pipeline-tests.json"))
        if failures > 0 { exit(1) }
    }
}
