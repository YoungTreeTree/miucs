import Foundation

/// Treble clef, sharp spelling. Adjacent diatonic steps are half a staff space.
struct StaffPitch: Equatable, Sendable {
    static let lineSpacing = 8.0
    static let middleY = 74.0 // B4
    static let supportedMIDI = 40...96 // E2...C7, matching the melody analyzer.
    let midi: Int

    init?(midi: Int) {
        guard Self.supportedMIDI.contains(midi) else { return nil }
        self.midi = midi
    }
    var isSharp: Bool { [1, 3, 6, 8, 10].contains(midi % 12) }
    var name: String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[midi % 12] + String(midi / 12 - 1)
    }
    var y: Double {
        let degrees = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        let degree = (midi / 12 - 1) * 7 + degrees[midi % 12]
        return Self.middleY - Double(degree - 34) * Self.lineSpacing / 2
    }
    var ledgerYs: [Double] {
        if y <= 50 { return stride(from: 50.0, through: y, by: -Self.lineSpacing).map { $0 } }
        if y >= 98 { return stride(from: 98.0, through: y, by: Self.lineSpacing).map { $0 } }
        return []
    }
    static func resolve(_ melody: MelodyFrame, previous: StaffPitch?) -> StaffPitch? {
        guard melody.isMelodic, melody.confidence.isFinite, melody.confidence >= 0.48,
              let hz = melody.pitchHz, hz.isFinite, hz > 0,
              let midi = melody.midi, midi.isFinite,
              midi >= Double(supportedMIDI.lowerBound) - 0.5,
              midi < Double(supportedMIDI.upperBound) + 0.5 else { return nil }
        // Fifteen cents of hysteresis prevent label/staff chatter near a boundary.
        if let previous, abs(midi - Double(previous.midi)) <= 0.65 { return previous }
        return StaffPitch(midi: Int(midi.rounded()))
    }
}
