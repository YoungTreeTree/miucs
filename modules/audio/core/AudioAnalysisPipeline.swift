import Foundation

/// One producer owns this state and calls it serially with decoded PCM blocks.
/// Analysis order and latest-melody pairing match the existing capture pipeline.
final class AudioAnalysisPipeline {
    private let features: AudioFeatureAnalyzer
    private let melody: any MelodyEstimating
    private var latestMelody: MelodyFrame?
    private var sampleRate: Double?
    private var channelCount: Int?
    private var vocals: (any VocalPCMProcessor)?
    private let requiresVocalInput: Bool
    private let onVocalFailure: (Error) -> Void
    private let onMelodyFailure: (Error) -> Void
    private var melodyFailed = false
    private var inputSamples: Int64 = 0
    private var melodyTimeOffset = 0.0

    init(features: AudioFeatureAnalyzer, melody: any MelodyEstimating,
         vocals: (any VocalPCMProcessor)? = nil,
         requiresVocalInput: Bool = false,
         onVocalFailure: @escaping (Error) -> Void = { _ in },
         onMelodyFailure: @escaping (Error) -> Void = { _ in }) {
        self.features = features; self.melody = melody
        self.vocals = vocals; self.onVocalFailure = onVocalFailure
        self.requiresVocalInput = requiresVocalInput; self.onMelodyFailure = onMelodyFailure
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
            melody.reset(); vocals?.reset()
            inputSamples = 0; melodyTimeOffset = 0
            sampleRate = block.sampleRate; channelCount = block.channels.count
        }
        let melodyBlock: AudioPCMBlock?
        if let vocals {
            do {
                melodyBlock = try vocals.process(block)
            } catch {
                // Separation failure must not interrupt level/onset capture.
                // Start fresh at this block's original PCM position on fallback.
                self.vocals = nil; melody.reset(); latestMelody = nil
                melodyTimeOffset = Double(inputSamples) / block.sampleRate
                onVocalFailure(error)
                melodyBlock = requiresVocalInput ? nil : block
            }
        } else { melodyBlock = requiresVocalInput ? nil : block }
        inputSamples += Int64(count)
        if !melodyFailed, let melodyBlock {
            do {
                if var last = try melody.process(channels: melodyBlock.channels, sampleRate: melodyBlock.sampleRate).last {
                    last.time += melodyTimeOffset
                    latestMelody = last
                }
            } catch {
                // A singing model failure must not silently start tracking the
                // accompaniment or stop level/onset/keyboard animations.
                guard requiresVocalInput else { throw error }
                melodyFailed = true; latestMelody = nil; melody.reset()
                onMelodyFailure(error)
            }
        }
        if vocals != nil, let last = latestMelody,
           Double(inputSamples) / block.sampleRate - last.time > 0.5 { latestMelody = nil }
        return try features.process(channels: block.channels, sampleRate: block.sampleRate).map { ($0, latestMelody) }
    }
}
