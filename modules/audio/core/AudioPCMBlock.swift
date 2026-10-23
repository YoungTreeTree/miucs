import Foundation

struct AudioPCMBlock: Sendable {
    var channels: [[Float]]
    var sampleRate: Double
    var isInterleaved: Bool
}
