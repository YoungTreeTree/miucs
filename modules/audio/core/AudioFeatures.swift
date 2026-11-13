import Foundation

public struct AudioFeatures: Codable, Sendable {
    public var time: Double
    public var sampleRate: Double
    public var channelCount: Int
    public var rms: Double
    public var rmsDBFS: Double
    public var peak: Double
    public var crestDB: Double?
    public var envelope: Double
    public var isSilent: Bool
    public var silenceDuration: Double
    public var lowEnergy: Double
    public var midEnergy: Double
    public var highEnergy: Double
    public var lowShare: Double?
    public var midShare: Double?
    public var highShare: Double?
    public var centroidHz: Double?
    public var bandwidthHz: Double?
    public var flatness: Double?
    public var spectralFlux: Double
    public var onsetThreshold: Double
    public var isOnset: Bool
    public var balance: Double?
    public var sideEnergyRatio: Double?
    public var correlation: Double?
    public var displayBands: [Float]
    /// Optional extension; absent in older recordings and synthetic inputs.
    public var beat: BeatFrame? = nil
}

public enum AudioAnalysisError: Error, CustomStringConvertible {
    case invalidInput(String)
    case fftUnavailable

    public var description: String {
        switch self {
        case .invalidInput(let reason): return reason
        case .fftUnavailable: return "Cannot create the audio FFT"
        }
    }
}
