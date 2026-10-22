import Foundation

/// Rolling semitone range for the current, live melody.
struct MelodyRange {
    private(set) var lower = 48.0
    private(set) var upper = 84.0
    private var history = [(time: Double, midi: Double)]()
    private var lastTime: Double?

    mutating func height(for frame: MelodyFrame) -> Double? {
        guard frame.isMelodic, frame.confidence >= 0.48, let midi = frame.midi, midi.isFinite else { return nil }
        if let lastTime, frame.time <= lastTime { return nil }
        let dt = min(max(frame.time - (lastTime ?? frame.time), 0), 0.2)
        lastTime = frame.time
        history.append((frame.time, midi))
        history.removeAll { $0.time < frame.time - 30 }
        if history.count >= 24, frame.time - history[0].time >= 3 {
            let values = history.map(\.midi).sorted()
            let lo = values[Int(Double(values.count - 1) * 0.10)] - 2
            let hi = values[Int(Double(values.count - 1) * 0.90)] + 2
            let center = (lo + hi) / 2, span = max(12, hi - lo)
            let limit = dt * 0.7
            lower += min(max(center - span / 2 - lower, -limit), limit)
            upper += min(max(center + span / 2 - upper, -limit), limit)
            if upper - lower < 12 { upper = lower + 12 }
        }
        let normalized = min(max((midi - lower) / (upper - lower), 0), 1)
        return 196 - normalized * 140
    }
}

/// Exact critically damped spring: continuous velocity, no fixed look-ahead buffer.
fileprivate struct FlightSpring {
    var position: Double
    var velocity = 0.0

    mutating func advance(to target: Double, frequency: Double, dt: Double) {
        let offset = position - target
        let impulse = velocity + frequency * offset
        let decay = exp(-frequency * dt)
        position = target + (offset + impulse * dt) * decay
        velocity = (velocity - frequency * impulse * dt) * decay
        if abs(position - target) < 0.0001 && abs(velocity) < 0.001 {
            position = target; velocity = 0
        }
    }
}

struct FlightGate: Identifiable, Sendable {
    var id: Int
    var x: Double
    var openingTop: Double
    var openingBottom: Double
    let restingCenter: Double
    let halfGap: Double
    fileprivate var motion: FlightSpring
    var passed = false
    static let halfWidth = 30.0 // Includes the widest animated pipe cap.
}
struct FlightParticle: Identifiable, Sendable {
    var id: Int
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var lifetime: Double
    var feather: Bool
}

/// Live melody sets the bird target without a route buffer. A short spring
/// smooths its motion; random gates yield without constraining that motion.
struct SoundFlightWorld {
    static let width = 400.0
    static let height = 260.0
    static let birdScreenX = 96.0
    static let birdRadiusX = 25.0 // Includes the beak, tail and rotated outline.
    static let birdRadiusY = 13.0
    private(set) var distance = 0.0
    var birdY: Double { birdMotion.position }
    private(set) var melodyTargetY = 126.0
    private var noteMIDI: Int?
    private var noteAge = Double.infinity
    /// The detected note, independently of the adaptive height range and flight spring.
    var melodyNoteName: String? {
        guard hasAudio, audio?.isSilent == false, audioAge < 0.4,
              noteAge < 0.24, let midi = noteMIDI else { return nil }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[midi % 12])\(midi / 12 - 1)"
    }
    var melodyNoteOpacity: Double {
        guard melodyNoteName != nil else { return 0.3 }
        return 0.88 * min(max((0.24 - noteAge) / 0.12, 0), 1)
    }
    var needsMotionUpdates: Bool {
        abs(birdY - melodyTargetY) > 0.001 || abs(birdMotion.velocity) > 0.01
    }
    private(set) var birdAngle = 0.0
    private(set) var score = 0
    private(set) var gates = [FlightGate]()
    private(set) var particles = [FlightParticle]()
    private(set) var activity = 0.0
    private(set) var flap = 0.0
    private(set) var loudness = 0.0
    private(set) var bass = 0.0
    private(set) var mids = 0.0
    private(set) var highs = 0.0
    private(set) var brightness = 0.5
    private(set) var scatter = 0.0
    private(set) var elapsed = 0.0
    private(set) var hasAudio = false
    private var range = MelodyRange()
    private var birdMotion = FlightSpring(position: 126)
    private var audio: AudioFeatures?
    private var audioAge = Double.infinity
    private var lastAudioTime = -Double.infinity
    private var lastMelodyTime = -Double.infinity
    private var pendingOnset = false
    private var nextGateDistance = 0.0
    private var randomState: UInt64
    private var nextGateID = 0
    private var nextParticleID = 0
    private var particleBudget = 0.0

    init(seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        randomState = seed
    }

    mutating func receive(audio frame: AudioFeatures?) {
        guard let frame else {
            audio = nil; hasAudio = false; pendingOnset = false
            lastAudioTime = -.infinity; lastMelodyTime = -.infinity
            range = MelodyRange()
            noteMIDI = nil; noteAge = .infinity
            return
        }
        guard frame.time != lastAudioTime else { return }
        lastAudioTime = frame.time; audioAge = 0; audio = frame; hasAudio = true
        if frame.isOnset && !frame.isSilent { pendingOnset = true }
    }

    mutating func receive(melody: MelodyFrame?) {
        guard let melody else { return }
        if melody.time < lastMelodyTime { range = MelodyRange() }
        lastMelodyTime = melody.time
        if let height = range.height(for: melody) {
            melodyTargetY = height
            if let midi = melody.midi, (0...127).contains(midi) {
                // A 15-cent boundary hysteresis avoids alternating names on vibrato.
                if noteAge >= 0.24 || noteMIDI.map({ abs(midi - Double($0)) > 0.65 }) != false {
                    noteMIDI = Int(midi.rounded())
                }
                noteAge = 0
            }
        }
    }

    mutating func advance(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        var remaining = min(seconds, 0.25)
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 120)
            step(dt); remaining -= dt
        }
    }

    private mutating func step(_ dt: Double) {
        elapsed += dt; audioAge += dt; noteAge += dt
        let active = audio.map { !$0.isSilent } == true && audioAge < 0.4
        let targetActivity = active ? 1.0 : 0.0
        activity += (targetActivity - activity) * (1 - exp(-dt / 0.28))
        if activity < 0.002 { activity = 0 }
        func drive(_ power: Double) -> Double {
            min(max((10 * log10(max(power, 1e-12)) + 60) / 45, 0), 1)
        }
        func smooth(_ value: inout Double, _ target: Double, _ tau: Double = 0.10) {
            value += (target - value) * (1 - exp(-dt / tau))
        }
        smooth(&loudness, active ? drive(pow(audio?.envelope ?? 0, 2)) : 0)
        smooth(&bass, active ? drive(audio?.lowEnergy ?? 0) : 0)
        smooth(&mids, active ? drive(audio?.midEnergy ?? 0) : 0, 0.3)
        smooth(&highs, active ? drive(audio?.highEnergy ?? 0) : 0)
        smooth(&brightness, min(max(log2(max(audio?.centroidHz ?? 1_000, 150) / 150) / 6, 0), 1), 1.2)
        smooth(&scatter, audio?.flatness ?? 0, 0.25)

        let speed = (96 + 30 * mids) * activity
        distance += speed * dt
        birdMotion.advance(to: melodyTargetY, frequency: 32, dt: dt)
        smooth(&birdAngle, min(max(birdMotion.velocity * 0.0015, -0.28), 0.28), 0.055)
        if active && distance >= nextGateDistance {
            // Spacing is independent of beat density; sustained notes still get gates.
            createGate(at: distance + 280)
            nextGateDistance = distance + 74 + randomUnit() * 16
        }
        avoidGates(dt: dt)
        flap *= exp(-dt / 0.14)
        if pendingOnset {
            pendingOnset = false
            if active {
                flap = 1
                emit(feather: true)
            }
        }
        for i in gates.indices where !gates[i].passed && gates[i].x + FlightGate.halfWidth + Self.birdRadiusX < distance {
            gates[i].passed = true; score += 1
        }
        gates.removeAll { $0.x < distance - Self.birdScreenX - 70 }
        particleBudget += highs * 24 * activity * dt
        if particleBudget >= 1 { particleBudget -= 1; emit(feather: false) }
        for i in particles.indices {
            particles[i].life -= dt
            particles[i].x += (particles[i].vx - speed * 0.5) * dt
            particles[i].y += particles[i].vy * dt
        }
        particles.removeAll { $0.life <= 0 || $0.x < 0 }
        if particles.count > 80 { particles.removeFirst(particles.count - 80) }
    }

    private mutating func createGate(at x: Double) {
        let center = 72 + randomUnit() * 108
        let halfGap = 40 + randomUnit() * 8
        gates.append(FlightGate(id: nextGateID, x: x, openingTop: center - halfGap,
                                openingBottom: center + halfGap, restingCenter: center,
                                halfGap: halfGap, motion: FlightSpring(position: center)))
        nextGateID += 1
    }

    private mutating func avoidGates(dt: Double) {
        let overlap = FlightGate.halfWidth + Self.birdRadiusX
        let clearance = Self.birdRadiusY + 14
        func ease(_ value: Double) -> Double {
            let t = min(max(value, 0), 1)
            return t * t * (3 - 2 * t)
        }
        // Rounded min/max are C1 continuous and always outside the safety envelope.
        // Expanding the gap lets a slow pipe yield to a fast bird without snapping.
        func softMin(_ a: Double, _ b: Double) -> Double {
            let h = max(10 - abs(a - b), 0) / 10
            return min(a, b) - h * h * 2.5
        }
        for i in gates.indices {
            let ahead = gates[i].x - distance
            guard ahead < 220 else { continue }
            var gate = gates[i]
            let approach = ease((220 - ahead) / 130) // Fully clear by 90 units.
            let release = 1 - ease((-ahead - overlap) / 90)
            let influence = approach * release
            let predictedY = min(max(birdY + birdMotion.velocity * 0.045, 56), 196)
            let target = ahead >= -overlap
                ? gate.restingCenter + (predictedY - gate.restingCenter) * approach
                : gate.motion.position
            gate.motion.advance(to: min(max(target, gate.halfGap + 8), 238 - gate.halfGap),
                                frequency: 14, dt: dt)
            let top = gate.motion.position - gate.halfGap
            let bottom = gate.motion.position + gate.halfGap
            gate.openingTop = top + (softMin(top, birdY - clearance) - top) * influence
            gate.openingBottom = bottom + (-softMin(-bottom, -birdY - clearance) - bottom) * influence
            gates[i] = gate
        }
    }

    private mutating func randomUnit() -> Double {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Double(randomState >> 11) / 9_007_199_254_740_992
    }

    private mutating func emit(feather: Bool) {
        let a = Self.noise(nextParticleID, 7), b = Self.noise(nextParticleID, 19)
        let lifetime = feather ? 0.65 : 0.9
        particles.append(FlightParticle(id: nextParticleID, x: Self.birdScreenX - 14,
                                       y: birdY + a * 4, vx: -12 - abs(a) * 16,
                                       vy: b * (8 + scatter * 35), life: lifetime,
                                       lifetime: lifetime, feather: feather))
        nextParticleID += 1
    }

    static func noise(_ index: Int, _ seed: Int) -> Double {
        let n = sin(Double(index &* 73 &+ seed &* 137) * 12.9898) * 43758.5453
        return (n - floor(n)) * 2 - 1
    }
}
