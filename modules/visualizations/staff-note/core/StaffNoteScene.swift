import Foundation

struct StaffTracePoint: Equatable, Sendable {
    let time: Double
    let pitch: StaffPitch
    /// Lightly smoothed notation height, independent of note animation and bounce.
    let y: Double
    let segment: Int
}

/// Logical coordinates stay fixed: loudness and decorative bounce never enter notation.
struct StaffNoteScene {
    static let width = 800.0, height = 160.0, noteX = 640.0
    static let historyDuration = 8.0, historyCapacity = 512
    static let trailSpeed = 70.0
    private(set) var elapsed = 0.0
    private(set) var pitch: StaffPitch?
    private(set) var targetY = StaffPitch.middleY
    private(set) var baseY = StaffPitch.middleY
    private(set) var bounce = 0.0
    private(set) var scale = 0.94
    private(set) var opacity = 0.22
    private(set) var labelOpacity = 0.0
    private(set) var isPitchReliable = false
    private(set) var trace = [StaffTracePoint]()
    private var velocity = 0.0, bounceVelocity = 0.0
    private var melodyAge = Double.infinity, audioAge = Double.infinity
    private var sounding = false, loudness = 0.0
    private var segment = 0
    private var pitchTracker = StaffPitchTracker()
    private var lastTraceMelodyTime: Double?
    var noteY: Double { baseY + bounce }
    var canBounce: Bool { sounding && audioAge < 0.4 && pitch != nil }
    var needsMotionUpdates: Bool {
        !trace.isEmpty || abs(baseY - targetY) > 0.001 || abs(velocity) > 0.01 ||
        abs(bounce) > 0.001 || abs(bounceVelocity) > 0.01 ||
        abs(scale - targetScale) > 0.001 || abs(opacity - targetOpacity) > 0.001 ||
        abs(labelOpacity - (isPitchReliable ? 1 : 0)) > 0.001
    }
    private var targetScale: Double { sounding && audioAge < 0.4 ? 0.94 + 0.17 * loudness : 0.94 }
    private var targetOpacity: Double { isPitchReliable ? 0.95 : 0.22 }

    mutating func receive(audio: AudioFeatures?, age: Double = 0) {
        guard let audio, age.isFinite, age >= 0, age < 0.4 else {
            sounding = false; audioAge = .infinity; invalidatePitch(); stopBounce(); return
        }
        audioAge = age; sounding = !audio.isSilent
        let envelope = audio.envelope.isFinite ? max(0, audio.envelope) : 0
        loudness = min(1, log1p(envelope * 40) / log(13))
        if !sounding { invalidatePitch(); stopBounce() }
    }

    /// Called once per new melody analysis result, with its age in the PCM/host timeline.
    mutating func receive(melody: MelodyFrame?, age: Double = 0) {
        guard sounding, age.isFinite, age >= 0, age < 0.24, let melody,
              let resolved = StaffPitch.resolve(melody, previous: isPitchReliable ? pitch : nil) else {
            invalidatePitch(); return
        }
        switch pitchTracker.receive(resolved, time: melody.time, previous: isPitchReliable ? pitch : nil) {
        case .ignored: return
        case .hold: break // Do not let unconfirmed candidates renew the last reliable pitch.
        case .accept(let accepted):
            pitch = accepted; targetY = accepted.y; melodyAge = age; isPitchReliable = true
        }
        guard isPitchReliable, let pitch else { return }
        let time = elapsed - age
        var y = pitch.y
        if let last = trace.last, last.segment == segment, let lastTraceMelodyTime {
            // A 25ms time constant softens corners without flattening genuine sustained notes.
            let dt = max(0, melody.time - lastTraceMelodyTime)
            y = last.y + (pitch.y - last.y) * (1 - exp(-dt / 0.025))
        }
        lastTraceMelodyTime = melody.time
        trace.append(StaffTracePoint(time: time, pitch: pitch, y: y, segment: segment))
        if trace.count > Self.historyCapacity { trace.removeFirst(trace.count - Self.historyCapacity) }
    }

    mutating func receiveOnset(strength: Double) {
        guard canBounce else { return }
        let effort = strength.isFinite ? min(1, max(0, strength)) : 0
        // A velocity impulse preserves position even when several onsets arrive together.
        bounceVelocity = max(-190, bounceVelocity - 100 - 45 * loudness - 25 * effort)
    }

    mutating func resetInput(clearHistory: Bool) {
        receive(audio: nil)
        melodyAge = .infinity
        if clearHistory { trace.removeAll(keepingCapacity: true) }
    }
    private mutating func invalidatePitch() {
        if isPitchReliable { segment += 1 }
        isPitchReliable = false
        pitchTracker.reset()
        lastTraceMelodyTime = nil
    }
    private mutating func stopBounce() {
        // Cancel a queued upward kick; an existing displacement returns smoothly.
        if bounceVelocity < 0 { bounceVelocity = 0 }
    }

    mutating func advance(seconds: Double) {
        elapse(seconds: seconds)
        animate(seconds: seconds)
    }
    /// History ages by wall-clock intervals, independently of bounded motion integration.
    mutating func elapse(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        elapsed += seconds; audioAge += seconds; melodyAge += seconds
        if audioAge >= 0.4 { sounding = false; stopBounce() }
        if melodyAge >= 0.24 || !sounding { invalidatePitch() }
        trace.removeAll { elapsed - $0.time >= Self.historyDuration }
        // Long scheduling gaps age history in full, without simulating old actions.
        if seconds > 0.25 { stopBounce() }
    }
    mutating func animate(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        let count = max(1, Int(ceil(min(seconds, 0.25) * 120)))
        let dt = min(seconds, 0.25) / Double(count)
        for _ in 0..<count {
            Self.spring(&baseY, velocity: &velocity, target: targetY, frequency: 40, dt: dt)
            baseY = min(146, max(14, baseY))
            Self.spring(&bounce, velocity: &bounceVelocity, target: 0, frequency: 30, dt: dt)
            if bounce < -4 { bounce = -4; bounceVelocity = max(0, bounceVelocity) }
            if bounce > 0 { bounce = 0; bounceVelocity = min(0, bounceVelocity) }
            let ease = 1 - exp(-dt / 0.055)
            scale += (targetScale - scale) * ease
            opacity += (targetOpacity - opacity) * ease
            labelOpacity += ((isPitchReliable ? 1.0 : 0.0) - labelOpacity) * ease
        }
    }
    private static func spring(_ position: inout Double, velocity: inout Double, target: Double,
                               frequency: Double, dt: Double) {
        let displacement = position - target
        let c = velocity + frequency * displacement, decay = exp(-frequency * dt)
        position = target + (displacement + c * dt) * decay
        velocity = (velocity - frequency * c * dt) * decay
    }
    func traceX(_ point: StaffTracePoint) -> Double { Self.noteX - max(0, elapsed - point.time) * Self.trailSpeed }
    func traceOpacity(_ point: StaffTracePoint) -> Double { max(0, 1 - max(0, elapsed - point.time) / Self.historyDuration) }
}
