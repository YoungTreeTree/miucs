import Foundation

/// Serial, streaming pitch estimation on the input PCM timeline.
protocol MelodyEstimating: AnyObject {
    /// Original mix, submitted before separation. Sample zero and format must
    /// match the delayed melody PCM; delivery time is not an alignment signal.
    func receiveMixture(channels: [[Float]], sampleRate: Double) throws
    func process(channels: [[Float]], sampleRate: Double) throws -> [MelodyFrame]
    func reset()
}

extension MelodyEstimating {
    func receiveMixture(channels: [[Float]], sampleRate: Double) throws {}
}

extension MelodyAnalyzer: MelodyEstimating {}
