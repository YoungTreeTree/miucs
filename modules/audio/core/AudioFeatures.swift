import Foundation

struct AudioFeatures: Codable, Sendable {
    var time: Double
    var sampleRate: Double
    var channelCount: Int
    var rms: Double
    var rmsDBFS: Double
    var peak: Double
    var crestDB: Double?
    var envelope: Double
    var isSilent: Bool
    var silenceDuration: Double
    var lowEnergy: Double
    var midEnergy: Double
    var highEnergy: Double
    var lowShare: Double?
    var midShare: Double?
    var highShare: Double?
    var centroidHz: Double?
    var bandwidthHz: Double?
    var flatness: Double?
    var spectralFlux: Double
    var onsetThreshold: Double
    var isOnset: Bool
    var balance: Double?
    var sideEnergyRatio: Double?
    var correlation: Double?
    var displayBands: [Float]
}

enum AudioAnalysisError: Error, CustomStringConvertible {
    case invalidInput(String)
    case fftUnavailable

    var description: String {
        switch self {
        case .invalidInput(let reason): return reason
        case .fftUnavailable: return "Cannot create the audio FFT"
        }
    }
}
