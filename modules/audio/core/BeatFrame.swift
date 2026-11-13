import Foundation

/// Causal pulse tracking on the original mix. Confidence is not a probability.
public struct BeatFrame: Codable, Sendable {
    public let time: Double
    public let bpm: Double?
    /// Fraction of a beat since the most recent metrical pulse, in 0..<1.
    public let phase: Double?
    public let confidence: Double
    public let strength: Double
    /// A newly due pulse in the PCM timeline; nil on all intervening windows.
    public let beatTime: Double?
}

public struct AudioBeatEvent: Codable, Sendable {
    public let sequence: UInt64
    public let time: Double
    public let receivedAt: Double
    public let strength: Double
    public let bpm: Double
    public let confidence: Double
}
