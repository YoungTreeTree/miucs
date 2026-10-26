import Foundation

struct MelodyFrame: Codable, Sendable {
    /// Center of the analysis window, in the same PCM timeline as AudioFeatures.
    var time: Double
    var pitchHz: Double?
    /// Estimator-specific reliability, not a calibrated voice probability.
    var confidence: Double
    var isMelodic: Bool
    var midi: Double? { pitchHz.map { 69 + 12 * log2($0 / 440) } }
}
