import Foundation

/// Causal pulse tracking on the original mix. Confidence is not a probability.
struct BeatFrame: Codable, Sendable {
    let time: Double
    let bpm: Double?
    /// Fraction of a beat since the most recent metrical pulse, in 0..<1.
    let phase: Double?
    let confidence: Double
    let strength: Double
    /// A newly due pulse in the PCM timeline; nil on all intervening windows.
    let beatTime: Double?
}

struct AudioBeatEvent: Codable, Sendable {
    let sequence: UInt64
    let time: Double
    let receivedAt: Double
    let strength: Double
    let bpm: Double
    let confidence: Double
}
