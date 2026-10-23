import Foundation

/// Queue-confined streaming analysis. A sample-rate/channel change starts a fresh timeline.
final class AudioFeatureAnalyzer {
    static let windowSize = 2048
    static let hopSize = 1024
    static let bandCount = 24
    static let silenceEnterDB = -60.0
    static let silenceExitDB = -54.0
    static let silenceHold = 0.15
    static let attackSeconds = 0.025
    static let releaseSeconds = 0.20

    private let transform: any SpectrumTransform
    private let window: [Float]
    private let windowSquaredSum: Double
    private var realInput = [Float](repeating: 0, count: windowSize)
    private var imaginaryInput = [Float](repeating: 0, count: windowSize)
    private var realOutput = [Float](repeating: 0, count: windowSize)
    private var imaginaryOutput = [Float](repeating: 0, count: windowSize)
    private var pending = [[Float]]()
    private var sampleRate = 0.0
    private var windowStart: Int64 = 0
    private var envelope = 0.0
    private var silent = true
    private var quietDuration = 0.0
    private var previousMagnitude: [Double]?
    private var fluxHistory = [Double]()
    private var lastOnset = -Double.infinity
    private var wasAboveOnset = false

    init(transform: any SpectrumTransform) throws {
        guard transform.size == Self.windowSize else { throw AudioAnalysisError.fftUnavailable }
        self.transform = transform
        // Periodic Hann. Power normalization uses its actual squared sum.
        window = (0..<Self.windowSize).map {
            Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(Self.windowSize)))
        }
        windowSquaredSum = window.reduce(0) { $0 + Double($1) * Double($1) }
    }

    func reset() {
        pending = []
        sampleRate = 0
        windowStart = 0
        envelope = 0
        silent = true
        quietDuration = 0
        previousMagnitude = nil
        fluxHistory = []
        lastOnset = -.infinity
        wasAboveOnset = false
    }

    func process(channels: [[Float]], sampleRate rate: Double) throws -> [AudioFeatures] {
        guard rate.isFinite, rate >= 8_000, rate <= 192_000 else {
            throw AudioAnalysisError.invalidInput("Unsupported sample rate: \(rate)")
        }
        guard (1...2).contains(channels.count),
              let count = channels.first?.count,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) })
        else { throw AudioAnalysisError.invalidInput("Expected finite, equally sized mono/stereo PCM") }
        guard count > 0 else { return [] }

        if rate != sampleRate || channels.count != pending.count {
            reset()
            sampleRate = rate
            pending = Array(repeating: [], count: channels.count)
        }
        for channel in channels.indices { pending[channel].append(contentsOf: channels[channel]) }
        var offset = 0
        var frames = [AudioFeatures]()
        while offset + Self.windowSize <= pending[0].count {
            let samples = pending.map { Array($0[offset..<(offset + Self.windowSize)]) }
            frames.append(analyze(samples))
            windowStart += Int64(Self.hopSize)
            offset += Self.hopSize
        }
        if offset > 0 {
            for channel in pending.indices { pending[channel].removeFirst(offset) }
        }
        return frames
    }

    private func analyze(_ channels: [[Float]]) -> AudioFeatures {
        let n = Self.windowSize
        let count = Double(n)
        let channelCount = Double(channels.count)
        let time = (Double(windowStart) + count / 2) / sampleRate
        let dt = Double(windowStart == 0 ? n : Self.hopSize) / sampleRate
        var sums = [Double](repeating: 0, count: channels.count)
        var squares = sums
        var peak = 0.0
        for channel in channels.indices {
            for sample in channels[channel] {
                let value = Double(sample)
                sums[channel] += value
                squares[channel] += value * value
                peak = max(peak, abs(value))
            }
        }
        let power = squares.reduce(0, +) / (count * channelCount)
        let rms = sqrt(power)
        let db = 20 * log10(max(rms, 1e-12))
        let tau = rms > envelope ? Self.attackSeconds : Self.releaseSeconds
        envelope += (rms - envelope) * (1 - exp(-dt / tau))

        if db < Self.silenceEnterDB {
            quietDuration += dt
            if quietDuration >= Self.silenceHold { silent = true }
        } else {
            quietDuration = 0
            if db >= Self.silenceExitDB { silent = false }
        }

        var balance: Double?
        var sideRatio: Double?
        var correlation: Double?
        if channels.count == 2, power > 1e-12 {
            let total = squares[0] + squares[1]
            balance = (squares[1] - squares[0]) / total
            var cross = 0.0
            var side = 0.0
            for i in 0..<n {
                let left = Double(channels[0][i]), right = Double(channels[1][i])
                cross += left * right
                side += (left - right) * (left - right) / 4
            }
            // Mid + Side energy = (Left + Right energy) / 2.
            sideRatio = min(max(side / (total / 2), 0), 1)
            let leftVariance = max(squares[0] - sums[0] * sums[0] / count, 0)
            let rightVariance = max(squares[1] - sums[1] * sums[1] / count, 0)
            let denominator = sqrt(leftVariance * rightVariance)
            if leftVariance / count > 1e-12, rightVariance / count > 1e-12 {
                correlation = min(max((cross - sums[0] * sums[1] / count) / denominator, -1), 1)
            }
        }

        // Average the channel POWERS. Averaging the waveforms would cancel anti-phase stereo.
        var spectralPower = [Double](repeating: 0, count: n / 2 + 1)
        for channel in channels.indices {
            let mean = sums[channel] / count
            for i in 0..<n { realInput[i] = Float(Double(channels[channel][i]) - mean) * window[i] }
            transform.forward(real: &realInput, imaginary: &imaginaryInput, realOutput: &realOutput, imaginaryOutput: &imaginaryOutput)
            for k in spectralPower.indices {
                let re = Double(realOutput[k]), im = Double(imaginaryOutput[k])
                let oneSided = (k == 0 || k == n / 2) ? 1.0 : 2.0
                spectralPower[k] += (re * re + im * im) * oneSided
                    / (count * windowSquaredSum * channelCount)
            }
        }
        let binHz = sampleRate / count
        let lowerBin = max(1, Int(ceil(20 / binHz)))
        let upperBin = min(n / 2, Int(floor(20_000 / binHz)))
        var low = 0.0, mid = 0.0, high = 0.0
        var magnitudeSum = 0.0, weightedSum = 0.0, logPowerSum = 0.0
        let maximumPower = spectralPower[lowerBin...upperBin].max() ?? 0
        let floorPower = max(maximumPower * 1e-12, 1e-24)
        var magnitude = [Double](repeating: 0, count: upperBin - lowerBin + 1)
        for k in lowerBin...upperBin {
            let frequency = Double(k) * binHz, p = spectralPower[k]
            if frequency < 250 { low += p }
            else if frequency < 4_000 { mid += p }
            else { high += p }
            // Float FFT round-off in distant bins otherwise inflates the second
            // spectral moment of a pure tone. Ignore bins >120 dB below the peak
            // for magnitude-weighted descriptors / flux, retaining raw band power.
            let m = p >= floorPower ? sqrt(p) : 0
            magnitude[k - lowerBin] = m
            magnitudeSum += m
            weightedSum += m * frequency
            logPowerSum += log(max(p, floorPower))
        }
        let audiblePower = low + mid + high
        let hasSpectrum = audiblePower > 1e-12 && rms > 1e-5
        var centroid: Double?, bandwidth: Double?, flatness: Double?
        if hasSpectrum {
            let center = weightedSum / magnitudeSum
            centroid = center
            var deviation = 0.0
            for k in lowerBin...upperBin {
                let delta = Double(k) * binHz - center
                deviation += magnitude[k - lowerBin] * delta * delta
            }
            bandwidth = sqrt(deviation / magnitudeSum)
            flatness = min(exp(logPowerSum / Double(magnitude.count))
                / (audiblePower / Double(magnitude.count)), 1)
        }

        var flux = 0.0
        if let previous = previousMagnitude, hasSpectrum, db >= Self.silenceEnterDB {
            var positiveDifference = 0.0
            for i in magnitude.indices { positiveDifference += max(magnitude[i] - previous[i], 0) }
            flux = min(positiveDifference / max(magnitudeSum, 1e-12), 1)
        }
        let median = Self.median(fluxHistory)
        let mad = Self.median(fluxHistory.map { abs($0 - median) })
        let threshold = max(0.18, median + 4 * 1.4826 * mad)
        let above = flux >= threshold
        let isOnset = previousMagnitude != nil && above && !wasAboveOnset && time - lastOnset >= 0.10
        if isOnset { lastOnset = time }
        wasAboveOnset = above
        previousMagnitude = hasSpectrum ? magnitude : Array(repeating: 0, count: magnitude.count)
        fluxHistory.append(flux)
        let historyCount = max(8, Int(sampleRate / Double(Self.hopSize)))
        if fluxHistory.count > historyCount { fluxHistory.removeFirst(fluxHistory.count - historyCount) }

        return AudioFeatures(
            time: time, sampleRate: sampleRate, channelCount: channels.count,
            rms: rms, rmsDBFS: db, peak: peak,
            crestDB: rms > 1e-12 ? 20 * log10(max(peak, 1e-12) / rms) : nil,
            envelope: envelope, isSilent: silent, silenceDuration: quietDuration,
            lowEnergy: low, midEnergy: mid, highEnergy: high,
            lowShare: hasSpectrum ? low / audiblePower : nil,
            midShare: hasSpectrum ? mid / audiblePower : nil,
            highShare: hasSpectrum ? high / audiblePower : nil,
            centroidHz: centroid, bandwidthHz: bandwidth, flatness: flatness,
            spectralFlux: flux, onsetThreshold: threshold, isOnset: isOnset,
            balance: balance, sideEnergyRatio: sideRatio, correlation: correlation,
            displayBands: displayBands(spectralPower, binHz: binHz)
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func displayBands(_ power: [Double], binHz: Double) -> [Float] {
        let minHz = 40.0, maxHz = min(16_000, sampleRate / 2)
        return (0..<Self.bandCount).map { index in
            let startHz = minHz * pow(maxHz / minHz, Double(index) / Double(Self.bandCount))
            let endHz = minHz * pow(maxHz / minHz, Double(index + 1) / Double(Self.bandCount))
            let first = min(max(Int(ceil(startHz / binHz)), 1), power.count - 1)
            let end = min(max(Int(ceil(endHz / binHz)), first + 1), power.count)
            let peakPower = power[first..<end].max() ?? 0
            // Display-only transfer: -70...-10 dB of window-corrected bin power.
            let db = 10 * log10(max(peakPower, 1e-20))
            return Float(min(max((db + 70) / 60, 0), 1))
        }
    }
}
