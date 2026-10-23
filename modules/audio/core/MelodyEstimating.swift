import Foundation

/// Serial, streaming pitch estimation on the input PCM timeline.
protocol MelodyEstimating: AnyObject {
    func process(channels: [[Float]], sampleRate: Double) throws -> [MelodyFrame]
    func reset()
}

extension MelodyAnalyzer: MelodyEstimating {}
