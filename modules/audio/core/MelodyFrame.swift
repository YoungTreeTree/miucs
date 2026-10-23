import Foundation

enum MelodyEstimator: String, Codable, Sendable { case crepe }

struct MelodyFrame: Codable, Sendable {
    /// Center of the analysis window, in the same PCM timeline as AudioFeatures.
    var time: Double
    var pitchHz: Double?
    /// Estimator-specific reliability, not a calibrated voice probability.
    var confidence: Double
    var isMelodic: Bool
    /// Missing in older recordings and in the spectral estimator.
    var estimator: MelodyEstimator? = nil
    var midi: Double? { pitchHz.map { 69 + 12 * log2($0 / 440) } }
}
