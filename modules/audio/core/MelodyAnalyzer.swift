import Foundation

/// Causal predominant-melody approximation: interpolated spectral peaks,
/// harmonic salience, subharmonic rejection and short contour continuity.
/// Does not mistake the spectral centroid or the largest FFT bin for a melody.
final class MelodyAnalyzer {
    static let windowSize = 4096
    static let hopSize = 1024
    private let transform: any SpectrumTransform
    private let window: [Float]
    private var input = [Float](repeating: 0, count: windowSize)
    private var imaginary = [Float](repeating: 0, count: windowSize)
    private var real = [Float](repeating: 0, count: windowSize)
    private var imag = [Float](repeating: 0, count: windowSize)
    private var pending = [[Float]]()
    private var rate = 0.0
    private var start: Int64 = 0
    private var previousMIDI: Double?
    private var lastReliableTime = -Double.infinity

    init(transform: any SpectrumTransform) throws {
        guard transform.size == Self.windowSize else { throw AudioAnalysisError.fftUnavailable }
        self.transform = transform
        window = (0..<Self.windowSize).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(Self.windowSize))) }
    }

    func reset() {
        pending = []; rate = 0; start = 0; previousMIDI = nil
        lastReliableTime = -.infinity
    }

    func process(channels: [[Float]], sampleRate: Double) throws -> [MelodyFrame] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (1...2).contains(channels.count), let count = channels.first?.count,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw AudioAnalysisError.invalidInput("Invalid melody PCM")
        }
        guard count > 0 else { return [] }
        if sampleRate != rate || channels.count != pending.count {
            reset(); rate = sampleRate; pending = Array(repeating: [], count: channels.count)
        }
        for c in channels.indices { pending[c].append(contentsOf: channels[c]) }
        var offset = 0, result = [MelodyFrame]()
        while offset + Self.windowSize <= pending[0].count {
            result.append(analyze(offset: offset))
            offset += Self.hopSize; start += Int64(Self.hopSize)
        }
        if offset > 0 { for c in pending.indices { pending[c].removeFirst(offset) } }
        return result
    }

    private struct Peak { var hz: Double; var magnitude: Double }

    private func analyze(offset: Int) -> MelodyFrame {
        let n = Self.windowSize, time = (Double(start) + Double(n) / 2) / rate
        var energy = 0.0
        var means = [Double]()
        for channel in pending {
            let samples = channel[offset..<(offset + n)]
            let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(n)
            means.append(mean)
            energy += samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        }
        let rms = sqrt(energy / Double(n * pending.count))
        func absent(_ confidence: Double = 0) -> MelodyFrame {
            if time - lastReliableTime > 0.35 { previousMIDI = nil }
            return MelodyFrame(time: time, pitchHz: nil, confidence: confidence, isMelodic: false)
        }
        guard rms > 0.0005 else { return absent() }
        var power = [Double](repeating: 0, count: n / 2 + 1)
        for (channelIndex, channel) in pending.enumerated() {
            let mean = means[channelIndex]
            for i in 0..<n {
                let v = Double(channel[offset + i])
                input[i] = Float(v - mean) * window[i]
            }
            transform.forward(real: &input, imaginary: &imaginary, realOutput: &real, imaginaryOutput: &imag)
            for i in power.indices {
                power[i] += (Double(real[i]) * Double(real[i]) + Double(imag[i]) * Double(imag[i])) / Double(pending.count)
            }
        }
        let binHz = rate / Double(n)
        let first = max(2, Int(60 / binHz)), last = min(n / 2 - 2, Int(8_000 / binHz))
        let maximum = power[first...last].max() ?? 0
        guard maximum > 0 else { return absent() }
        var peaks = [Peak]()
        for k in first...last where power[k] > power[k - 1] && power[k] >= power[k + 1] && power[k] > maximum * 0.0001 {
            let a = log(max(power[k - 1], 1e-24)), b = log(max(power[k], 1e-24)), c = log(max(power[k + 1], 1e-24))
            let denominator = a - 2 * b + c
            let delta = abs(denominator) > 1e-12 ? min(max(0.5 * (a - c) / denominator, -0.5), 0.5) : 0
            peaks.append(Peak(hz: (Double(k) + delta) * binHz, magnitude: sqrt(power[k])))
        }
        let total = power[first...last].reduce(0, +)
        peaks.sort { $0.magnitude > $1.magnitude }
        if peaks.count > 60 { peaks.removeLast(peaks.count - 60) }
        // Recompute concentration from selected peaks only: broadband noise must not
        // look tonal merely because it has many local FFT maxima.
        let selectedEnergy = peaks.reduce(0.0) { sum, p in
            let k = min(max(Int((p.hz / binHz).rounded()), first), last)
            return sum + power[k - 1] + power[k] + power[k + 1]
        }
        let tonality = min(selectedEnergy / max(total, 1e-12), 1)
        guard tonality > 0.42, let strongest = peaks.first else { return absent() }

        // 10-cent salience bins, E2...C7. A mild register weighting suppresses
        // bass accompaniment without hard-coding the melody as a high note.
        let minimumMIDI = 40.0, resolution = 10.0, bins = 561
        var salience = [Double](repeating: 0, count: bins)
        for peak in peaks {
            let magnitude = pow(peak.magnitude / strongest.magnitude, 0.8)
            for harmonic in 1...10 {
                let midi = 69 + 12 * log2(peak.hz / Double(harmonic) / 440)
                let position = (midi - minimumMIDI) * resolution
                guard position >= 0, position <= Double(bins - 1) else { continue }
                let center = Int(position.rounded())
                for i in max(0, center - 3)...min(bins - 1, center + 3) {
                    let distance = (Double(i) - position) / 3
                    salience[i] += magnitude * pow(0.8, Double(harmonic - 1)) * exp(-2 * distance * distance)
                }
            }
        }
        var candidates = [(midi: Double, score: Double, support: Double)]()
        for i in 1..<(bins - 1) where salience[i] > salience[i - 1] && salience[i] >= salience[i + 1] {
            let midi = minimumMIDI + Double(i) / resolution, hz = 440 * pow(2, (midi - 69) / 12)
            var fundamental = 0.0, odd = 0.0, matching = 0.0
            for peak in peaks {
                let harmonic = Int((peak.hz / hz).rounded())
                guard (1...10).contains(harmonic) else { continue }
                let cents = abs(1200 * log2(peak.hz / (hz * Double(harmonic))))
                if cents < 40 {
                    let strength = peak.magnitude / strongest.magnitude
                    matching += strength
                    if harmonic == 1 { fundamental = max(fundamental, strength) }
                    if harmonic % 2 == 1 { odd += strength }
                }
            }
            let subharmonicPenalty = fundamental < 0.04 && odd < 0.08 ? 0.28 : 1.0
            let register = midi < 48 ? 0.62 : midi > 88 ? 0.8 : 1.0
            let score = salience[i] * subharmonicPenalty * register
            candidates.append((midi, score, min(matching, 1)))
        }
        guard let maximumScore = candidates.map(\.score).max(), maximumScore > 0 else { return absent() }
        let plausible = candidates.filter { $0.score >= maximumScore * 0.55 }
        let chosen = plausible.max { a, b in
            func value(_ item: (midi: Double, score: Double, support: Double)) -> Double {
                let continuity = previousMIDI.map { min(abs(item.midi - $0) * 0.025, 0.24) } ?? 0
                return item.score / maximumScore - continuity
            }
            return value(a) < value(b)
        }!
        let confidence = min(max((tonality - 0.35) / 0.55, 0), 1) * min(1, chosen.score / maximumScore) * chosen.support
        guard confidence >= 0.48 else { return absent(confidence) }

        // A reliable current estimate is published without waiting for another
        // frame to confirm a jump. Continuity still participates in candidate selection.
        previousMIDI = chosen.midi; lastReliableTime = time
        return MelodyFrame(time: time, pitchHz: 440 * pow(2, (chosen.midi - 69) / 12), confidence: confidence, isMelodic: true)
    }
}
