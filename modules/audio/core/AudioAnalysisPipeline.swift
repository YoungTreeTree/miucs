import Foundation

/// One producer owns this state and calls it serially with decoded PCM blocks.
/// Analysis order and latest-melody pairing match the existing capture pipeline.
final class AudioAnalysisPipeline {
    private let features: AudioFeatureAnalyzer
    private let melody: MelodyAnalyzer
    private var latestMelody: MelodyFrame?
    private var sampleRate: Double?
    private var channelCount: Int?

    init(features: AudioFeatureAnalyzer, melody: MelodyAnalyzer) {
        self.features = features; self.melody = melody
    }

    func process(_ block: AudioPCMBlock) throws -> [(audio: AudioFeatures, melody: MelodyFrame?)] {
        if sampleRate != block.sampleRate || channelCount != block.channels.count {
            latestMelody = nil
            sampleRate = block.sampleRate; channelCount = block.channels.count
        }
        let melodies = try melody.process(channels: block.channels, sampleRate: block.sampleRate)
        if let last = melodies.last { latestMelody = last }
        return try features.process(channels: block.channels, sampleRate: block.sampleRate).map { ($0, latestMelody) }
    }
}
