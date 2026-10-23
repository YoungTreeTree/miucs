import Foundation

/// Expands the current passage's dynamics without changing the measured audio envelope.
struct StaffVolumeTracker {
    private(set) var contrast = 0.5
    private var lastTime: Double?
    private var lowerDB = 0.0, upperDB = 0.0

    mutating func reset() { self = Self() }

    mutating func receive(envelope: Double, time: Double) {
        guard time.isFinite, envelope.isFinite, envelope >= 0,
              lastTime.map({ time > $0 }) ?? true else { return }
        let db = 20 * log10(max(envelope, 1e-6))
        if let lastTime {
            // Extrema expand immediately and relax over three seconds of PCM time.
            let ease = 1 - exp(-(time - lastTime) / 3)
            lowerDB = min(db, lowerDB + (db - lowerDB) * ease)
            upperDB = max(db, upperDB + (db - upperDB) * ease)
        } else {
            lowerDB = db; upperDB = db
        }
        lastTime = time
        // A minimum 12dB range keeps steady tones and tiny fluctuations stable.
        let span = max(12, upperDB - lowerDB)
        let center = (lowerDB + upperDB) / 2
        contrast = min(1, max(0, 0.5 + (db - center) / span))
    }
}
