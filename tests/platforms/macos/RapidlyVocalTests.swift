import Foundation
import RapidlyEngineC

@main
enum RapidlyVocalTests {
    static func main() throws {
        let model = URL(fileURLWithPath: "build/rapidly/\(RapidlyConfiguration.modelName)")
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func block(_ count: Int, rate: Double = 48_000, channels: Int = 2, offset: Int = 0) -> AudioPCMBlock {
            let tone = (0..<count).map { Float(0.1 * sin(Double(offset + $0) * .pi * 2 * 220 / rate)) }
            return AudioPCMBlock(channels: .init(repeating: tone, count: channels), sampleRate: rate, isInterleaved: false)
        }
        let configuration = RapidlyConfiguration(modelURL: model, licenseFile: nil)
        let processor = try RapidlyVocalProcessor(configuration: configuration)
        check("Actual SDK music model loads in explicit watermarked demo mode",
              !processor.hasAcceptedOfflineKey && processor.statusDescription.contains("水印") &&
              processor.busNames == ["vocals", "bass", "guitar", "drums", "piano", "residual"] &&
              abs(processor.maximumLatencySeconds - 0.096) < 1e-6)
        let warmup = try processor.process(block(512))
        check("Warm-up waits for actual output rather than returning raw PCM", warmup == nil)
        var consumed = 512, produced = 0, finite = true
        for count in [33, 480, 2048, 511, 8192, 512] {
            if let out = try processor.process(block(count, offset: consumed)) {
                produced += out.channels[0].count
                finite = finite && out.channels.count == 2 && out.sampleRate == 48_000 &&
                    out.channels.allSatisfy { $0.count == out.channels[0].count && $0.allSatisfy(\.isFinite) }
            }
            consumed += count
        }
        check("Variable-size stereo capture blocks produce bounded finite vocal PCM", finite && produced > 4096 && produced <= consumed)
        processor.reset()
        let afterReset = try processor.process(block(512))
        check("Reset discards pending audio and restarts model warm-up", afterReset == nil)
        let changed = try processor.process(block(8192, rate: 44_100, channels: 1))
        check("Sample-rate and channel changes recreate the native processor",
              changed?.channels.count == 1 && changed?.sampleRate == 44_100 && (changed?.channels[0].count ?? 0) > 0)
        var invalidRejected = false
        do { _ = try processor.process(AudioPCMBlock(channels: [[.infinity]], sampleRate: 48_000, isInterleaved: false)) }
        catch { invalidRejected = true }
        check("Non-finite PCM is rejected before calling the SDK", invalidRejected)
        var missingRejected = false
        do { _ = try RapidlyVocalProcessor(configuration: RapidlyConfiguration(modelURL: model.appendingPathExtension("missing"), licenseFile: nil)) }
        catch RapidlyFailure.missingModel { missingRejected = true }
        check("Missing model produces a recoverable initialization error", missingRejected)
        let keyFile = URL(fileURLWithPath: "build/rapidly/unsupported-test-key.txt")
        try "sk_not_a_real_key".write(to: keyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: keyFile) }
        var unsupportedRejected = false
        do { _ = try RapidlyVocalProcessor(configuration: RapidlyConfiguration(modelURL: model, licenseFile: keyFile)) }
        catch RapidlyFailure.unsupportedLicense { unsupportedRejected = true }
        check("Online keys are rejected before registration; this integration stays offline", unsupportedRejected)

        // Verify timestamp semantics using normal bus recombination, leaving
        // demo watermarking intact. This is independent of any song labels.
        var alignment = [[String: Any]]()
        for rate in [48_000.0, 44_100.0] {
            guard let handle = rapidlyCreateProcessor(model.path, 1, rate) else { throw RapidlyFailure.model }
            defer { rapidlyDeleteProcessor(handle) }
            for bus in 0..<rapidlyGetNumOfOutputBusses(handle) {
                rapidlySetParameterValue(handle, Int32(RAPIDLY_PARAM_BUS_GAINS) + bus, 1)
            }
            var seed: UInt64 = 123
            let original = (0..<Int(rate)).map { _ -> Float in
                seed = seed &* 6364136223846793005 &+ 1
                return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.2
            }
            let padded = original + [Float](repeating: 0, count: 8192)
            var reconstructed = [Float]()
            for offset in stride(from: 0, to: padded.count, by: 512) {
                let pcm = Array(padded[offset..<min(offset + 512, padded.count)])
                rapidlyAddAudioInterleaved(handle, pcm, Int32(pcm.count))
                let n = rapidlyGetNumOfPendingSamples(handle)
                if n > 0 {
                    var output = [Float](repeating: 0, count: Int(n))
                    guard rapidlyGetAudioInterleaved(handle, &output, n) else { throw RapidlyFailure.output }
                    reconstructed += output
                }
            }
            var bestLag = 0, bestScore = -Double.infinity
            for lag in -64...64 {
                var score = 0.0
                for i in 128..<(original.count - 128) { score += Double(original[i]) * Double(reconstructed[i + lag]) }
                if score > bestScore { bestScore = score; bestLag = lag }
            }
            alignment.append(["sampleRate": rate, "outputLagSamples": bestLag])
            check("\(Int(rate)) Hz SDK output sample zero uses the original PCM timeline", bestLag == 0)
        }
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures,
            "checks": checks, "alignment": alignment, "mode": "unlicensed demo; watermark intact"], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/rapidly-vocal-tests.json"))
        if failures > 0 { exit(1) }
    }
}
