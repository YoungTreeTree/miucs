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
        guard block.sampleRate.isFinite, (8_000...192_000).contains(block.sampleRate),
              (1...2).contains(block.channels.count), let count = block.channels.first?.count,
              block.channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw AudioAnalysisError.invalidInput("Invalid analysis PCM")
        }
        guard count > 0 else { return [] }
        if sampleRate != block.sampleRate || channelCount != block.channels.count {
            latestMelody = nil
            melody.reset()
            sampleRate = block.sampleRate; channelCount = block.channels.count
        }
        if let last = try melody.process(channels: block.channels, sampleRate: block.sampleRate).last {
            latestMelody = last
        }
        return try features.process(channels: block.channels, sampleRate: block.sampleRate).map { ($0, latestMelody) }
    }

}
