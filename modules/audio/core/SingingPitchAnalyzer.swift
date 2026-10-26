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
    private let usesMixtureReference: Bool
    private let resampler = StreamingMonoResampler()
    private let mixtureResampler = StreamingMonoResampler()
    private var pending = [Float]()
    private var mixturePending = [Float]()
    private var mixtureStart: Int64 = 0
    private var mixtureEnergies = [Int64: Double]()
    private var sampleRate = 0.0, channelCount = 0
    private var start: Int64 = 0
    private var gate: SingingVoicingGate

    init(predictor: any SingingPitchPredicting, usesMixtureReference: Bool = false) {
        self.predictor = predictor; self.usesMixtureReference = usesMixtureReference
        gate = SingingVoicingGate(usesMixtureReference: usesMixtureReference)
    }

    /// Two seconds covers separation latency while bounding stalled-input memory.
    static let maximumReferenceFrames = 100
    var bufferedReferenceFrames: Int { mixtureEnergies.count }

    func reset() {
        resampler.reset(); pending.removeAll(keepingCapacity: true)
        mixtureResampler.reset(); mixturePending.removeAll(keepingCapacity: true)
        mixtureEnergies.removeAll(keepingCapacity: true); mixtureStart = 0
        sampleRate = 0; channelCount = 0; start = 0; gate.reset()
    }

    private func prepare(channels: [[Float]], sampleRate: Double) throws -> Int {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (1...2).contains(channels.count), let count = channels.first?.count,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw AudioAnalysisError.invalidInput("Invalid singing pitch PCM")
        }
        guard count > 0 else { return 0 }
        if self.sampleRate != sampleRate || channelCount != channels.count {
            reset(); self.sampleRate = sampleRate; channelCount = channels.count
        }
        return count
    }

    func receiveMixture(channels: [[Float]], sampleRate: Double) throws {
        guard usesMixtureReference, try prepare(channels: channels, sampleRate: sampleRate) > 0 else { return }
        mixturePending += mixtureResampler.process(channels: channels, sampleRate: sampleRate)
        var offset = 0
        while offset + Self.windowSize <= mixturePending.count {
            let window = mixturePending[offset..<(offset + Self.windowSize)]
            mixtureEnergies[mixtureStart] = Self.rms(window)
            mixtureEnergies.removeValue(forKey: mixtureStart - Int64(Self.maximumReferenceFrames * Self.hopSize))
            offset += Self.hopSize; mixtureStart += Int64(Self.hopSize)
        }
        if offset > 0 { mixturePending.removeFirst(offset) }
    }

    func process(channels: [[Float]], sampleRate: Double) throws -> [MelodyFrame] {
        guard try prepare(channels: channels, sampleRate: sampleRate) > 0 else { return [] }
        pending += resampler.process(channels: channels, sampleRate: sampleRate)
        var offset = 0, results = [MelodyFrame]()
        while offset + Self.windowSize <= pending.count {
            let samples = Array(pending[offset..<(offset + Self.windowSize)])
            let rms = Self.rms(samples[...])
            let time = (Double(start) + Double(Self.windowSize) / 2) / StreamingMonoResampler.outputRate
            // Match the exact original PCM window, never the most recently
            // delivered mix level. Missing/expired reference fails closed.
            let mixtureRMS = mixtureEnergies.removeValue(forKey: start)
            let audible = gate.acceptsEnergy(rms: rms, mixtureRMS: mixtureRMS)
            let estimate = audible ? try predictor.predict(samples) : nil
            let voiced = gate.receive(estimate: estimate, rms: rms, time: time, mixtureRMS: mixtureRMS)
            results.append(MelodyFrame(time: time, pitchHz: voiced ? estimate?.pitchHz : nil,
                confidence: estimate?.periodicity ?? 0, isMelodic: voiced, estimator: .crepe))
            offset += Self.hopSize; start += Int64(Self.hopSize)
        }
        if offset > 0 { pending.removeFirst(offset) }
        return results
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
}

/// Reject silence/noise before publishing a note; a weak posterior can never
/// keep an old note alive. Entry requires consecutive support; release is immediate.
struct SingingVoicingGate {
    static let minimumRMS = 0.000562341325 // -65 dBFS, independent of mix volume.
    static let onsetPeriodicity = 0.60, sustainPeriodicity = 0.50
    static let relativeOnsetPeriodicity = 0.40, relativeSustainPeriodicity = 0.30
    static let minimumVocalToMixtureRMS = 0.35481338923357547 // -9 dB amplitude ratio.
    let usesMixtureReference: Bool
    private(set) var voiced = false
    private var candidateTime: Double?
    private var lastTime: Double?

    init(usesMixtureReference: Bool = false) { self.usesMixtureReference = usesMixtureReference }
    mutating func reset() { voiced = false; candidateTime = nil; lastTime = nil }

    func acceptsEnergy(rms: Double, mixtureRMS: Double?) -> Bool {
        guard rms.isFinite, rms >= Self.minimumRMS else { return false }
        guard usesMixtureReference else { return true }
        guard let mixtureRMS, mixtureRMS.isFinite, mixtureRMS >= Self.minimumRMS else { return false }
        return rms >= mixtureRMS * Self.minimumVocalToMixtureRMS
    }

    mutating func receive(estimate: SingingPitchEstimate?, rms: Double, time: Double,
                          mixtureRMS: Double? = nil) -> Bool {
        if let lastTime, time <= lastTime || time - lastTime > 0.06 { reset() }
        lastTime = time
        let onset = usesMixtureReference ? Self.relativeOnsetPeriodicity : Self.onsetPeriodicity
        let sustain = usesMixtureReference ? Self.relativeSustainPeriodicity : Self.sustainPeriodicity
        guard time.isFinite, acceptsEnergy(rms: rms, mixtureRMS: mixtureRMS),
              let estimate, estimate.pitchHz.isFinite, (31...2006).contains(estimate.pitchHz),
              estimate.periodicity.isFinite,
              estimate.periodicity >= (voiced ? sustain : onset) else {
            voiced = false; candidateTime = nil; return false
        }
        if !voiced {
            if candidateTime == nil { candidateTime = time }
            voiced = time - candidateTime! >= 0.019 // Two 20ms observations.
        }
        return voiced
    }
}
