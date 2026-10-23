import Foundation

/// Queue-confined, causal PCM transformation used only by melody analysis.
/// Output sample zero refers to input sample zero. Buffering delays delivery,
/// not the PCM timeline; callers must not timestamp it with the delivery time.
protocol VocalPCMProcessor: AnyObject {
    func process(_ block: AudioPCMBlock) throws -> AudioPCMBlock?
    func reset()
}
