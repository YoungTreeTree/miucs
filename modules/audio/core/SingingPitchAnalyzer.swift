import Foundation

struct SingingPitchEstimate {
    let pitchHz: Double
    /// CREPE's peak activation, not a calibrated voice probability.
    let periodicity: Double
}

protocol SingingPitchPredicting: AnyObject {
    func predict(_ samples: [Float]) throws -> SingingPitchEstimate
}

/// Causal CREPE framing and voicing gate; no interpolation through unvoiced spans.
final class SingingPitchAnalyzer: MelodyEstimating {
    static let windowSize = 1024, hopSize = 320
    private let predictor: any SingingPitchPredicting
    private let resampler = StreamingMonoResampler()
    private var pending = [Float]()
    private var sampleRate = 0.0, channelCount = 0
    private var start: Int64 = 0
    private var gate = SingingVoicingGate()

    init(predictor: any SingingPitchPredicting) { self.predictor = predictor }

    func reset() {
        resampler.reset(); pending.removeAll(keepingCapacity: true)
        sampleRate = 0; channelCount = 0; start = 0; gate.reset()
    }

    func process(channels: [[Float]], sampleRate: Double) throws -> [MelodyFrame] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (1...2).contains(channels.count), let count = channels.first?.count,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw AudioAnalysisError.invalidInput("Invalid singing pitch PCM")
        }
        guard count > 0 else { return [] }
        if self.sampleRate != sampleRate || channelCount != channels.count {
            reset(); self.sampleRate = sampleRate; channelCount = channels.count
        }
        pending += resampler.process(channels: channels, sampleRate: sampleRate)
        var offset = 0, results = [MelodyFrame]()
        while offset + Self.windowSize <= pending.count {
            let samples = Array(pending[offset..<(offset + Self.windowSize)])
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            let time = (Double(start) + Double(Self.windowSize) / 2) / StreamingMonoResampler.outputRate
            let estimate = rms >= SingingVoicingGate.minimumRMS ? try predictor.predict(samples) : nil
            let voiced = gate.receive(estimate: estimate, rms: rms, time: time)
            results.append(MelodyFrame(time: time, pitchHz: voiced ? estimate?.pitchHz : nil,
                confidence: estimate?.periodicity ?? 0, isMelodic: voiced, estimator: .crepe))
            offset += Self.hopSize; start += Int64(Self.hopSize)
        }
        if offset > 0 { pending.removeFirst(offset) }
        return results
    }
}

/// Reject silence/noise before publishing a note; a weak posterior can never
/// keep an old note alive. Entry requires consecutive support; release is immediate.
struct SingingVoicingGate {
    static let minimumRMS = 0.000562341325 // -65 dBFS, independent of mix volume.
    static let onsetPeriodicity = 0.60, sustainPeriodicity = 0.50
    private(set) var voiced = false
    private var candidateTime: Double?
    private var lastTime: Double?

    mutating func reset() { voiced = false; candidateTime = nil; lastTime = nil }

    mutating func receive(estimate: SingingPitchEstimate?, rms: Double, time: Double) -> Bool {
        if let lastTime, time <= lastTime || time - lastTime > 0.06 { reset() }
        lastTime = time
        guard time.isFinite, rms.isFinite, rms >= Self.minimumRMS,
              let estimate, estimate.pitchHz.isFinite, (31...2006).contains(estimate.pitchHz),
              estimate.periodicity.isFinite,
              estimate.periodicity >= (voiced ? Self.sustainPeriodicity : Self.onsetPeriodicity) else {
            voiced = false; candidateTime = nil; return false
        }
        if !voiced {
            if candidateTime == nil { candidateTime = time }
            voiced = time - candidateTime! >= 0.019 // Two 20ms observations.
        }
        return voiced
    }
}
