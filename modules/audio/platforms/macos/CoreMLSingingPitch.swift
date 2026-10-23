import CoreML
import Foundation

/// One audio queue owns this model and its reusable input. Model preparation
/// happens off the main thread; runtime inference has no tasks or network I/O.
final class CoreMLSingingPitch: SingingPitchPredicting {
    private let model: MLModel
    private let input: MLMultiArray
    private let provider: MLDictionaryFeatureProvider

    static func bundledURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "SingingPitch", withExtension: "mlmodelc", subdirectory: "SingingPitch") else {
            throw AudioAnalysisError.invalidInput("缺少歌声音高模型，请使用 --rapidly 构建")
        }
        return url
    }

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        // The small full-float neural-network model is validated on CPU.
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: config)
        input = try MLMultiArray(shape: [1, 1024], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
        // Avoid lazy execution setup on the first audible note.
        let tone = (0..<1024).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / 16_000)) }
        let check = try predict(tone)
        guard abs(1200 * log2(check.pitchHz / 440)) < 20, check.periodicity > 0.8 else {
            throw AudioAnalysisError.invalidInput("歌声音高模型自检失败")
        }
    }

    func predict(_ samples: [Float]) throws -> SingingPitchEstimate {
        guard samples.count == 1024 else { throw AudioAnalysisError.invalidInput("Invalid singing model window") }
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / 1024
        let variance = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / 1023
        let scale = max(sqrt(variance), 1e-10)
        for i in samples.indices { pointer[i] = Float((Double(samples[i]) - mean) / scale) }
        guard let activation = try model.prediction(from: provider).featureValue(for: "activation")?.multiArrayValue,
              activation.count == 360 else { throw AudioAnalysisError.invalidInput("Invalid singing model output") }
        let values = (0..<360).map { activation[$0].doubleValue }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              let peak = values.indices.max(by: { values[$0] < values[$1] }) else {
            throw AudioAnalysisError.invalidInput("Nonfinite singing model output")
        }
        // CREPE's original nine-bin local weighted average. All pitch bins
        // participate in peak selection: do not force an out-of-range tone inward.
        var total = 0.0, weightedCents = 0.0
        for i in max(0, peak - 4)...min(359, peak + 4) {
            total += values[i]
            weightedCents += values[i] * (1997.3794084376191 + Double(i) * 20)
        }
        guard total > 0 else { return SingingPitchEstimate(pitchHz: 440, periodicity: 0) }
        return SingingPitchEstimate(pitchHz: 10 * pow(2, weightedCents / total / 1200), periodicity: values[peak])
    }
}
