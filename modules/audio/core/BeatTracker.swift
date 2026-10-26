import Foundation

/// Bounded, causal tempo/phase tracker. No model, UI clock, or future PCM.
/// Resample continuous onset novelty to 50Hz, correlate candidate periods, then
/// phase-lock a pulse clock. Subdivisions are evidence, not individual beats.
struct BeatTracker {
    static let minimumBPM = 50.0, maximumBPM = 200.0
    static let minimumConfidence = 0.45
    private static let step = 0.02, historyLimit = 400
    private var values = [Double]()
    private var gridTime = 0.0, nextGridTime = 0.0
    private var lastTime: Double?, lastNovelty = 0.0, previousLow = 0.0
    private var previousGrid = 0.0, olderGrid = 0.0
    private var fluxMean = 0.0, lastActivity = -Double.infinity
    private var lastAnalysis = -Double.infinity
    private var period: Double?, nextBeat: Double?, lastBeat = -Double.infinity
    private var score = 0.0, lastSupport = -Double.infinity
    private var proposedPeriod: Double?, proposedCount = 0

    mutating func reset() { self = Self() }

    mutating func process(time: Double, flux: Double, lowEnergy: Double, silent: Bool) -> BeatFrame? {
        guard time.isFinite, time >= 0, flux.isFinite, lowEnergy.isFinite,
              (0...1).contains(flux), lowEnergy >= 0 else { reset(); return nil }
        if let lastTime, time == lastTime { return nil }
        if let lastTime, time < lastTime || time - lastTime > 0.2 { reset() }
        // Keep zero-valued history across the quiet spaces between drum hits,
        // while suppressing output throughout silence. A long pause relearns.
        if silent, time - lastActivity > 2.5 { reset(); return empty(at: time) }
        guard let previousTime = lastTime else {
            lastTime = time; nextGridTime = time; previousLow = lowEnergy
            fluxMean = flux; lastActivity = time; return empty(at: time)
        }
        let dt = time - previousTime
        let lowRise = min(1, max(0, log10((lowEnergy + 1e-12) / (previousLow + 1e-12))))
        let novelty = silent ? 0 : max(0, flux - 1.15 * fluxMean - 0.015) + 0.20 * lowRise
        fluxMean += (flux - fluxMean) * (1 - exp(-dt / 0.7))
        previousLow = lowEnergy
        if novelty > 0.045 { lastActivity = time }
        while nextGridTime <= time + 1e-9 {
            let fraction = min(1, max(0, (nextGridTime - previousTime) / dt))
            let raw = lastNovelty + (novelty - lastNovelty) * fraction
            // A 40ms triangular kernel prevents fractional-period sampling from
            // favouring a 2x/3x interval whose lag happens to be an integer.
            values.append(0.25 * olderGrid + 0.5 * previousGrid + 0.25 * raw)
            olderGrid = previousGrid; previousGrid = raw
            gridTime = nextGridTime; nextGridTime += Self.step
        }
        if values.count > Self.historyLimit { values.removeFirst(values.count - Self.historyLimit) }
        lastTime = time; lastNovelty = novelty

        if time - lastAnalysis >= 0.25, values.count >= 110 {
            analyze(at: time); lastAnalysis = time
        }
        guard let period, let next = nextBeat else { return empty(at: time) }
        let nearest = next + ((time - next) / period).rounded() * period
        if abs(time - nearest) < min(0.10, period * 0.20), novelty > 0.045 { lastSupport = time }
        let coast = max(0, time - lastSupport - period * 1.2)
        let confidence = min(1, max(0, score * exp(-coast / max(0.15, period * 0.5))))
        guard time - lastActivity < max(0.8, period * 1.8), confidence >= Self.minimumConfidence else {
            nextBeat = nil
            return BeatFrame(time: time, bpm: nil, phase: nil, confidence: confidence, strength: 0, beatTime: nil)
        }
        var due: Double?
        if time >= next, !silent || time - next > 0.08 {
            // Deliver at most one current pulse; never replay a backlog after a stall.
            if !silent, time - next <= 0.08, next - lastBeat >= period * 0.55 { due = next; lastBeat = next }
            nextBeat = next + Double(max(1, Int(floor((time - next) / period)) + 1)) * period
        }
        let phase = ((time - next) / period).truncatingRemainder(dividingBy: 1)
        let recent = values.suffix(5).max() ?? 0
        let peak = max(0.08, values.max() ?? 0.08)
        let strength = min(1, max(0.2, recent / peak))
        if silent { return empty(at: time) }
        return BeatFrame(time: time, bpm: 60 / period, phase: phase < 0 ? phase + 1 : phase,
                         confidence: confidence, strength: strength, beatTime: due)
    }

    private mutating func analyze(at time: Double) {
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        let minLag = Int(60 / Self.maximumBPM / Self.step), maxLag = Int(60 / Self.minimumBPM / Self.step)
        var correlations = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var cross = 0.0, first = 0.0, second = 0.0
            for i in lag..<centered.count {
                let a = centered[i], b = centered[i - lag]
                cross += a * b; first += a * a; second += b * b
            }
            correlations[lag] = cross / max(1e-10, sqrt(first * second))
        }
        var candidates = [(period: Double, correlation: Double)]()
        for lag in minLag...maxLag {
            let value = correlations[lag]
            guard value > 0.35, value >= correlations[lag - 1], value >= correlations[lag + 1] else { continue }
            let denominator = correlations[lag - 1] - 2 * value + correlations[lag + 1]
            let offset = abs(denominator) > 1e-9 ? min(0.5, max(-0.5,
                0.5 * (correlations[lag - 1] - correlations[lag + 1]) / denominator)) : 0
            let interval = min(60 / Self.minimumBPM, max(60 / Self.maximumBPM, (Double(lag) + offset) * Self.step))
            guard Double(values.count) * Self.step >= interval * 3 else { continue }
            candidates.append((interval, value))
        }
        guard var best = candidates.max(by: { $0.correlation < $1.correlation }) else {
            score *= 0.75; proposedPeriod = nil; proposedCount = 0; return
        }
        // Prefer the fundamental pulse to its 2x/3x interval when both explain
        // equally strong repeated attacks. Accented subdivisions can still lose.
        for candidate in candidates.sorted(by: { $0.period < $1.period }) where candidate.period < best.period {
            let ratio = best.period / candidate.period
            if abs(ratio - ratio.rounded()) < 0.08, ratio.rounded() >= 2,
               candidate.correlation >= best.correlation * 0.85 { best = candidate; break }
        }
        if let period, let stable = candidates.first(where: { abs($0.period / period - 1) < 0.06 }),
           stable.correlation >= best.correlation * 0.92 { best = stable }
        if period == nil, best.correlation < 0.55 {
            proposedPeriod = nil; proposedCount = 0; return
        }
        if period.map({ abs(best.period / $0 - 1) > 0.08 }) ?? true {
            if let proposal = proposedPeriod, abs(best.period / proposal - 1) < 0.05 { proposedCount += 1 }
            else { proposedPeriod = best.period; proposedCount = 1 }
            if proposedCount < 3 { score *= 0.9; return }
            self.period = best.period; nextBeat = nil
        } else {
            self.period = period.map { $0 + (best.period - $0) * 0.25 } ?? best.period
        }
        proposedCount = 0; proposedPeriod = nil
        guard let period = self.period else { return }
        score = best.correlation

        // Align to the strongest phase of the most recent eight pulses.
        let lag = period / Self.step
        var bestOffset = 0, bestEnergy = -Double.infinity
        for offset in 0..<Int(ceil(lag)) {
            var energy = 0.0, weight = 1.0, total = 0.0
            for cycle in 0..<8 {
                let index = Double(values.count - 1 - offset) - Double(cycle) * lag
                if index < 1 { break }
                energy += sample(at: index) * weight; total += weight; weight *= 0.85
            }
            energy /= max(1, total)
            if energy > bestEnergy { bestEnergy = energy; bestOffset = offset }
        }
        let anchor = gridTime - Double(bestOffset) * Self.step
        guard bestEnergy > max(0.04, mean * 1.5) else { score *= 0.5; return }
        if let nextBeat {
            let aligned = anchor + ((nextBeat - anchor) / period).rounded() * period
            self.nextBeat = nextBeat + min(0.02, max(-0.02, (aligned - nextBeat) * 0.3))
        } else if time - lastActivity < period * 1.5 {
            nextBeat = time - anchor < 0.06 && anchor - lastBeat >= period * 0.55 ? anchor : anchor + period
            lastSupport = anchor
        }
    }

    private func sample(at index: Double) -> Double {
        let lower = max(0, min(values.count - 1, Int(index)))
        let upper = min(values.count - 1, lower + 1)
        return values[lower] + (values[upper] - values[lower]) * (index - Double(lower))
    }
    private func empty(at time: Double) -> BeatFrame {
        BeatFrame(time: time, bpm: nil, phase: nil, confidence: 0, strength: 0, beatTime: nil)
    }
}
