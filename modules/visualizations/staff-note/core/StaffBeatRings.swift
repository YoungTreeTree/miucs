import Foundation

enum StaffBeatArc: Sendable { case main, satellite }

struct StaffBeatRing: Sendable, Equatable {
    let x: Double
    let y: Double
    let radius: Double
    let opacity: Double
    let lineWidth: Double
    let rotation: Double
    let arc: StaffBeatArc

    init(x: Double, y: Double, radius: Double, opacity: Double, lineWidth: Double = 1.05, rotation: Double = 0, arc: StaffBeatArc = .main) {
        self.x = x; self.y = y
        self.radius = radius; self.opacity = opacity; self.lineWidth = lineWidth
        self.rotation = rotation; self.arc = arc
    }
}

/// Beat pulses have their own lifetime. They never change the pitch, scale or sway.
struct StaffBeatRings {
    static let pulseLimit = 4
    static let satellitesPerPulse = 3
    static let limit = pulseLimit * (2 + satellitesPerPulse)
    static let ringLifetime = 0.8
    static let innerDelay = 0.09
    static let satelliteLifetime = 0.58
    static let satelliteDelay = 0.10
    static let satelliteStagger = 0.055
    static let lifetime = ringLifetime + innerDelay
    static let maximumEventAge = 0.15
    static let horizontalRange = 112.0...712.0
    static let verticalRange = 48.0...112.0
    private struct Satellite { let dx: Double, dy: Double, radius: Double, angle: Double }
    private struct Pulse {
        let born: Double, strength: Double, x: Double, y: Double, phase: Double
        let satellites: [Satellite]
    }
    private var pulses = [Pulse]()
    private var randomState: UInt64
    private var previousX: Double?
    private var elapsed = 0.0
    private var sequence: UInt64 = 0
    private(set) var rings = [StaffBeatRing]()
    private(set) var totalPulses: UInt64 = 0

    init(seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        randomState = seed
        pulses.reserveCapacity(Self.pulseLimit); rings.reserveCapacity(Self.limit)
    }

    @discardableResult
    mutating func clear(through sequence: UInt64 = 0) -> Bool {
        let changed = !rings.isEmpty
        pulses.removeAll(keepingCapacity: true); rings.removeAll(keepingCapacity: true)
        elapsed = 0; self.sequence = sequence; totalPulses = 0; previousX = nil
        return changed
    }

    @discardableResult
    mutating func advance(seconds: Double, events: [AudioBeatEvent], now: Double, through cursor: UInt64) -> Bool {
        let wasVisible = !rings.isEmpty
        if seconds.isFinite, seconds > 0 { elapsed += seconds }
        pulses.removeAll { elapsed - $0.born >= Self.lifetime }
        for event in events where event.sequence > sequence && event.sequence <= cursor {
            sequence = event.sequence
            let age = now - event.receivedAt
            guard age.isFinite, age >= 0, age <= Self.maximumEventAge,
                  event.strength.isFinite, (0...1).contains(event.strength),
                  event.confidence.isFinite, (BeatTracker.minimumConfidence...1).contains(event.confidence),
                  event.bpm.isFinite, (BeatTracker.minimumBPM...BeatTracker.maximumBPM).contains(event.bpm) else { continue }
            if pulses.count == Self.pulseLimit { pulses.removeFirst() }
            let origin = nextOrigin()
            let phase = randomUnit() * 2 * Double.pi
            var satellites = [Satellite]()
            for i in 0..<Self.satellitesPerPulse {
                let angle = phase * 1.31 + [0.4, 2.5, 4.55][i]
                let distance = Double(28 + i * 6)
                satellites.append(Satellite(dx: cos(angle) * distance, dy: sin(angle) * distance * 0.8,
                                            radius: [6.2, 8.3, 5.3][i], angle: angle))
            }
            pulses.append(Pulse(born: elapsed - age, strength: event.strength, x: origin.x, y: origin.y,
                                phase: phase, satellites: satellites))
            totalPulses &+= 1
        }
        sequence = max(sequence, cursor)
        rings.removeAll(keepingCapacity: true)
        for pulse in pulses {
            let age = elapsed - pulse.born
            for layer in 0..<2 {
                let localAge = age - Double(layer) * Self.innerDelay
                guard localAge >= 0, localAge < Self.ringLifetime else { continue }
                let t = localAge / Self.ringLifetime, expansion = 1 - pow(1 - t, 3)
                rings.append(StaffBeatRing(x: pulse.x, y: pulse.y, radius: 4 + (layer == 0 ? 28 : 20) * expansion,
                    opacity: min(1, localAge / 0.035) * pow(1 - t, 1.1) * (layer == 0 ? 0.73 : 0.48) * (0.85 + 0.15 * pulse.strength),
                    lineWidth: layer == 0 ? 1.05 : 0.72, rotation: pulse.phase + Double(layer) * 0.2))
            }
            for (i, satellite) in pulse.satellites.enumerated() {
                let localAge = age - Self.satelliteDelay - Double(i) * Self.satelliteStagger
                guard localAge >= 0, localAge < Self.satelliteLifetime else { continue }
                let t = localAge / Self.satelliteLifetime
                let expansion = 1 - pow(1 - t, 3), travel = 0.7 + 0.3 * expansion
                rings.append(StaffBeatRing(x: pulse.x + satellite.dx * travel, y: pulse.y + satellite.dy * travel,
                    radius: 1.5 + (satellite.radius - 1.5) * expansion,
                    opacity: min(1, localAge / 0.06) * 0.55 * pow(1 - t, 1.2) * (0.85 + 0.15 * pulse.strength),
                    lineWidth: 0.65, rotation: satellite.angle, arc: .satellite))
            }
        }
        return wasVisible || !rings.isEmpty
    }

    /// Only a new beat chooses the main center; satellite motion is cached with that beat.
    private mutating func nextOrigin() -> (x: Double, y: Double) {
        let width = Self.horizontalRange.upperBound - Self.horizontalRange.lowerBound
        var x = Self.horizontalRange.lowerBound + randomUnit() * width
        if let previousX, abs(x - previousX) < 120 {
            x = Self.horizontalRange.lowerBound +
                (x - Self.horizontalRange.lowerBound + width / 2).truncatingRemainder(dividingBy: width)
        }
        previousX = x
        let y = Self.verticalRange.lowerBound + randomUnit() * (Self.verticalRange.upperBound - Self.verticalRange.lowerBound)
        return (x, y)
    }

    private mutating func randomUnit() -> Double {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Double(randomState >> 11) / 9_007_199_254_740_992
    }
}
