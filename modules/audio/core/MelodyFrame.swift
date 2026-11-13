import Foundation

public struct MelodyFrame: Codable, Sendable {
    /// Center of the analysis window, in the same PCM timeline as AudioFeatures.
    public var time: Double
    public var pitchHz: Double?
    /// Estimator-specific reliability, not a calibrated voice probability.
    public var confidence: Double
    public var isMelodic: Bool
    public var midi: Double? { pitchHz.map { 69 + 12 * log2($0 / 440) } }
}
