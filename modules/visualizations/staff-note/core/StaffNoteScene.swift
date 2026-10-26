import Foundation

struct StaffTraceJoin: Equatable, Sendable {
    let startedAt: Double
    let duration: Double

    func progress(at time: Double) -> Double {
        let t = min(1, max(0, (time - startedAt) / duration))
        return t * t * (3 - 2 * t)
    }
}

struct StaffTracePoint: Equatable, Sendable {
    let time: Double
    let pitch: StaffPitch
    /// Lightly smoothed notation height, independent of note animation and sway.
    let y: Double
    let segment: Int
    /// Presentation time starts when the result arrives, independently of model latency.
    let join: StaffTraceJoin?
}

/// Logical coordinates stay fixed: loudness and decorative sway never enter notation.
struct StaffNoteScene {
    static let width = 800.0, height = 160.0, noteX = 640.0
    static let historyDuration = 8.0, historyCapacity = 512
    static let trailSpeed = 70.0
    static let maximumSwayAngle = 20.0 * Double.pi / 180
    private(set) var elapsed = 0.0
    private(set) var pitch: StaffPitch?
    /// Absolute treble-clef position: prior phrases never transpose an accepted pitch.
    private(set) var targetY = StaffPitch.middleY
    private(set) var baseY = StaffPitch.middleY
    /// Radians around the note head center; the head itself never translates sideways.
    private(set) var swayAngle = 0.0
    private(set) var scale = 0.94
    private(set) var opacity = 0.22
    private(set) var labelOpacity = 0.0
    private(set) var isPitchReliable = false
    private(set) var trace = [StaffTracePoint]()
    private var velocity = 0.0, angularVelocity = 0.0
    private var nextSwayDirection = -1.0
    private var melodyAge = Double.infinity, audioAge = Double.infinity
    private var sounding = false, loudness = 0.0
    private var segment = 0
    /// Pitch filtering must not turn one audible phrase into disconnected visual fragments.
    private var referencePitch: StaffPitch?
    private var pitchTracker = StaffPitchTracker()
    private var volumeTracker = StaffVolumeTracker()
    private var lastTraceMelodyTime: Double?
    private var lastObservationTime: Double?
    var noteCenterX: Double { Self.noteX }
    var noteY: Double { baseY }
    var hasContinuousTraceTail: Bool {
        sounding && isPitchReliable && audioAge < 0.4 && lastTraceMelodyTime != nil &&
            trace.last.map { $0.segment == segment } == true
    }
    var canSway: Bool { sounding && isPitchReliable && audioAge < 0.4 && pitch != nil }
    var needsMotionUpdates: Bool {
        !trace.isEmpty || abs(baseY - targetY) > 0.001 || abs(velocity) > 0.01 ||
        abs(swayAngle) > 0.001 || abs(angularVelocity) > 0.01 ||
        abs(scale - targetScale) > 0.001 || abs(opacity - targetOpacity) > 0.001 ||
        abs(labelOpacity - (isPitchReliable ? 1 : 0)) > 0.001
    }
    private var targetScale: Double { sounding && audioAge < 0.4 ? 0.8 + 0.7 * volumeTracker.contrast : 0.94 }
    private var targetOpacity: Double { isPitchReliable ? 0.95 : 0.22 }

    mutating func receive(audio: AudioFeatures?, age: Double = 0) {
        guard let audio, age.isFinite, age >= 0, age < 0.4 else {
            sounding = false; audioAge = .infinity; volumeTracker.reset()
            lastObservationTime = nil
            resetMelodyInput(); stopSway(); return
        }
        audioAge = age; sounding = !audio.isSilent
        let envelope = audio.envelope.isFinite ? max(0, audio.envelope) : 0
        loudness = min(1, log1p(envelope * 40) / log(13))
        if sounding {
            volumeTracker.receive(envelope: envelope, time: audio.time)
        } else {
            lastObservationTime = nil
            volumeTracker.reset(); resetMelodyInput(); stopSway()
        }
    }

    /// Called once per new melody analysis result, with its age in the PCM/host timeline.
    mutating func receive(melody: MelodyFrame?, age: Double = 0) {
        guard sounding, age.isFinite, age >= 0, age < 0.24 else {
            invalidatePitch(); pitchTracker.reset(); return
        }
        if let melody {
            guard melody.time.isFinite, lastObservationTime.map({ melody.time > $0 }) ?? true else { return }
            lastObservationTime = melody.time
        }
        // Missing F0 invalidates the note, not the continuous music session.
        // Leave history untouched and join it only when another real point arrives.
        if let melody, !melody.isMelodic || melody.pitchHz == nil {
            resetPitchContext()
            stopSway(); return
        }
        guard let melody, melody.time.isFinite,
              let resolved = StaffPitch.resolve(melody, previous: referencePitch) else {
            // Do not move to an edge, extend history, or let a dropout bypass jump confirmation.
            pitchTracker.reset(); return
        }
        let reconnecting = !hasContinuousTraceTail
        switch pitchTracker.receive(resolved, time: melody.time, previous: referencePitch) {
        case .ignored: return
        case .hold: return
        case .accept(let accepted):
            pitch = accepted; referencePitch = accepted
            targetY = accepted.y; melodyAge = age; isPitchReliable = true
        }
        guard isPitchReliable, let pitch else { return }
        let time = elapsed - age
        var y = pitch.y
        var join: StaffTraceJoin?
        if let last = trace.last, last.segment == segment, let lastTraceMelodyTime {
            // A 25ms time constant softens corners without flattening genuine sustained notes.
            let dt = max(0, melody.time - lastTraceMelodyTime)
            y = last.y + (pitch.y - last.y) * (1 - exp(-dt / 0.025))
            if reconnecting, dt >= 0.08 - 1e-9 {
                join = StaffTraceJoin(startedAt: elapsed, duration: 0.18 + min(0.12, dt * 0.12))
            }
        }
        lastTraceMelodyTime = melody.time
        trace.append(StaffTracePoint(time: time, pitch: pitch, y: y, segment: segment, join: join))
        if trace.count > Self.historyCapacity { trace.removeFirst(trace.count - Self.historyCapacity) }
    }

    mutating func receiveOnset(strength: Double) {
        guard canSway else { return }
        let effort = strength.isFinite ? min(1, max(0, strength)) : 0
        // An angular impulse preserves the current tilt and keeps the head center fixed.
        let impulse = (300 + 135 * loudness + 100 * effort) * Double.pi / 180
        let limit = 600.0 * Double.pi / 180
        angularVelocity = min(limit, max(-limit, angularVelocity + nextSwayDirection * impulse))
        nextSwayDirection *= -1
    }

    mutating func resetInput(clearHistory: Bool) {
        receive(audio: nil)
        melodyAge = .infinity
        lastObservationTime = nil
        nextSwayDirection = -1
        if clearHistory { trace.removeAll(keepingCapacity: true) }
    }
    private mutating func invalidatePitch() {
        isPitchReliable = false
    }
    private mutating func breakTrace() {
        if lastTraceMelodyTime != nil { segment += 1 }
        lastTraceMelodyTime = nil
    }
    private mutating func resetPitchContext() {
        invalidatePitch(); pitchTracker.reset(); referencePitch = nil
    }
    private mutating func resetMelodyInput() {
        resetPitchContext(); breakTrace()
    }
    private mutating func stopSway() {
        // Cancel outward impulses while preserving a smooth return to the upright angle.
        if swayAngle * angularVelocity >= 0 { angularVelocity = 0 }
    }

    mutating func advance(seconds: Double) {
        elapse(seconds: seconds)
        animate(seconds: seconds)
    }
    /// History ages by wall-clock intervals, independently of bounded motion integration.
    mutating func elapse(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        elapsed += seconds; audioAge += seconds; melodyAge += seconds
        if audioAge >= 0.4 { sounding = false; stopSway() }
        if !sounding { resetMelodyInput() }
        else if melodyAge >= 0.24 {
            invalidatePitch()
        }
        trace.removeAll { elapsed - $0.time >= Self.historyDuration }
        if trace.isEmpty { breakTrace() }
        // Long scheduling gaps age history in full, without simulating old actions.
        if seconds > 0.25 { stopSway() }
    }
    mutating func animate(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        let count = max(1, Int(ceil(min(seconds, 0.25) * 120)))
        let dt = min(seconds, 0.25) / Double(count)
        for _ in 0..<count {
            Self.spring(&baseY, velocity: &velocity, target: targetY, frequency: 40, dt: dt)
            baseY = min(146, max(14, baseY))
            if canSway {
                Self.swaySpring(&swayAngle, velocity: &angularVelocity, dt: dt)
            } else {
                Self.spring(&swayAngle, velocity: &angularVelocity, target: 0, frequency: 30, dt: dt)
            }
            if swayAngle < -Self.maximumSwayAngle { swayAngle = -Self.maximumSwayAngle; angularVelocity = max(0, angularVelocity) }
            if swayAngle > Self.maximumSwayAngle { swayAngle = Self.maximumSwayAngle; angularVelocity = min(0, angularVelocity) }
            let ease = 1 - exp(-dt / 0.055)
            scale += (targetScale - scale) * ease
            opacity += (targetOpacity - opacity) * ease
            labelOpacity += ((isPitchReliable ? 1.0 : 0.0) - labelOpacity) * ease
        }
    }
    private static func swaySpring(_ position: inout Double, velocity: inout Double, dt: Double) {
        // Exact damped oscillation crosses the center and decays consistently across frame rates.
        let damping = 5.0, frequency = 12.0
        let start = position, sine = sin(frequency * dt), cosine = cos(frequency * dt)
        let decay = exp(-damping * dt)
        position = decay * (start * cosine + (velocity + damping * start) / frequency * sine)
        velocity = decay * (velocity * cosine -
            (damping * velocity + (damping * damping + frequency * frequency) * start) / frequency * sine)
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
