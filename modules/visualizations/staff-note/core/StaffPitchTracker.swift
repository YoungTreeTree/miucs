import Foundation

/// Rejects brief excursions while leaving semitone and whole-tone motion immediate.
/// Confirmation uses distinct PCM timestamps, never the number of display refreshes.
struct StaffPitchTracker {
    enum Decision {
        case ignored
        case hold
        case accept(StaffPitch)
    }
    private struct Pending {
        let anchorMIDI: Int
        let since: Double
        var frames: Int
    }
    private var pending: Pending?
    private var lastTime: Double?

    mutating func reset() { pending = nil; lastTime = nil }

    mutating func receive(_ candidate: StaffPitch, time: Double, previous: StaffPitch?) -> Decision {
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else { return .ignored }
        // Sparse observations cannot confirm that a new pitch was sustained.
        if let lastTime, time - lastTime > 0.075 { pending = nil }
        lastTime = time
        guard let previous else { pending = nil; return .accept(candidate) }
        let distance = abs(candidate.midi - previous.midi)
        guard distance > 2 else { pending = nil; return .accept(candidate) }

        if var current = pending, abs(candidate.midi - current.anchorMIDI) <= 1 {
            current.frames += 1; pending = current
        } else {
            pending = Pending(anchorMIDI: candidate.midi, since: time, frames: 1)
        }
        let required: (seconds: Double, frames: Int)
        switch distance {
        case 3...5: required = (0.02, 2)
        case 6...10: required = (0.04, 3)
        default: required = (0.06, 4)
        }
        guard let pending, pending.frames >= required.frames,
              time - pending.since + 1e-9 >= required.seconds else { return .hold }
        self.pending = nil
        return .accept(candidate)
    }
}
