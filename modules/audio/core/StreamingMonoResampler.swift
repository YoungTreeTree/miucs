import Foundation

/// Band-limited, centered resampling with a bounded 1.5ms look-ahead.
/// Sample zero remains sample zero; arbitrary capture block boundaries do not
/// change the phase. The left edge is zero padded, the live right edge is not.
final class StreamingMonoResampler {
    static let outputRate = 16_000.0
    private var rate = 0.0, position = 0.0
    private var radius = 0, origin = 0
    private var samples = [Float]()
    private var kernels = [[Float]]()
    private let phaseCount = 128

    func reset() {
        rate = 0; position = 0; origin = 0
        samples.removeAll(keepingCapacity: true); kernels.removeAll(keepingCapacity: true)
    }

    func process(channels: [[Float]], sampleRate: Double) -> [Float] {
        if rate != sampleRate {
            reset(); rate = sampleRate
            radius = Int(ceil(12 * max(1, sampleRate / Self.outputRate)))
            let cutoff = min(1, Self.outputRate / sampleRate) * 0.94
            kernels = (0..<phaseCount).map { phase in
                let fraction = Double(phase) / Double(phaseCount)
                var values = (-radius...radius).map { offset -> Float in
                    let x = Double(offset) - fraction
                    let sinc = abs(x) < 1e-10 ? cutoff : sin(.pi * cutoff * x) / (.pi * x)
                    let window = 0.5 + 0.5 * cos(.pi * x / Double(radius + 1))
                    return Float(sinc * window)
                }
                let sum = values.reduce(0, +)
                for i in values.indices { values[i] /= sum }
                return values
            }
        }
        for i in channels[0].indices {
            samples.append(channels.reduce(Float(0)) { $0 + $1[i] } / Float(channels.count))
        }
        let step = sampleRate / Self.outputRate
        var output = [Float]()
        output.reserveCapacity(Int(Double(samples.count) / step))
        while Int(floor(position)) + radius < origin + samples.count {
            let center = Int(floor(position))
            let phase = min(phaseCount - 1, Int((position - Double(center)) * Double(phaseCount)))
            let kernel = kernels[phase]
            var sum: Float = 0
            for k in kernel.indices {
                let index = center + k - radius - origin
                if index >= 0 { sum += samples[index] * kernel[k] }
            }
            output.append(sum); position += step
        }
        let consumed = max(0, min(samples.count, Int(floor(position)) - radius - origin))
        if consumed > 0 { samples.removeFirst(consumed); origin += consumed }
        return output
    }
}
