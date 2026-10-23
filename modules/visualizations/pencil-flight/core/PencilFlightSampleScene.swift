import Foundation

enum PencilFlightSampleScene {
    /// Fixed synthetic scene for the palette and offline checks; never reads audio.
    static func make() -> SoundFlightWorld {
        var world = SoundFlightWorld(seed: 42)
        let notes = [60.0, 64, 67, 72, 67, 64, 62, 69]
        for tick in 0..<1_080 {
            let t = Double(tick) / 60
            let pulse = tick % 36 == 0
            let audio = AudioFeatures(
                time: t, sampleRate: 48_000, channelCount: 2,
                rms: 0.08, rmsDBFS: -22, peak: 0.2, crestDB: 8,
                envelope: 0.08, isSilent: false, silenceDuration: 0,
                lowEnergy: 0.002 + (pulse ? 0.01 : 0), midEnergy: 0.003, highEnergy: 0.001,
                lowShare: 0.3, midShare: 0.5, highShare: 0.2, centroidHz: 2_000,
                bandwidthHz: 1_500, flatness: 0.15, spectralFlux: pulse ? 0.8 : 0.05,
                onsetThreshold: 0.2, isOnset: pulse, balance: 0, sideEnergyRatio: 0.2,
                correlation: 0.6, displayBands: Array(repeating: 0.5, count: 24)
            )
            world.receive(audio: audio)
            let midi = notes[(tick / 54) % notes.count]
            world.receive(melody: MelodyFrame(time: t, pitchHz: 440 * pow(2, (midi - 69) / 12), confidence: 1, isMelodic: true))
            world.advance(seconds: 1.0 / 60)
        }
        return world
    }

}
