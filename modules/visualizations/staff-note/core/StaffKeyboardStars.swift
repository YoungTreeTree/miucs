import Foundation

struct StaffStar: Sendable, Equatable {
    let x: Double
    let y: Double
    let radius: Double
    let rotation: Double
    let opacity: Double
}

/// Independent of audio time, UI frameworks and OS key-repeat settings.
struct StaffKeyboardStars {
    static let burstLimit = 16
    static let starLimit = 112
    static let lifetime = 0.650
    private struct Particle {
        let radius: Double, dx: Double, dy: Double, rotation: Double, spin: Double
    }
    private struct Burst {
        let key: StaffKeyboardKey
        let born: Double
        let small: Bool
        let particles: [Particle]
    }
    private struct Hold { let key: StaffKeyboardKey; var next: Double }
    private let keys: [UInt16: StaffKeyboardKey]
    private var bursts = [Burst]()
    private var held = [UInt16: Hold]()
    private var sessionID: UUID?
    private var sequence: UInt64 = 0
    private var capsLocked: Bool?
    private var elapsed = 0.0
    private(set) var totalBursts: UInt64 = 0
    private(set) var stars = [StaffStar]()
    var burstCount: Int { bursts.count }
    var hasLiveStars: Bool { !bursts.isEmpty }

    init(keys: [UInt16: StaffKeyboardKey]) {
        self.keys = keys
        bursts.reserveCapacity(Self.burstLimit)
        stars.reserveCapacity(Self.starLimit)
    }

    mutating func clear() {
        bursts.removeAll(keepingCapacity: true); stars.removeAll(keepingCapacity: true)
        held.removeAll(keepingCapacity: true); sessionID = nil; sequence = 0
        capsLocked = nil
        elapsed = 0; totalBursts = 0
    }

    /// Age old particles first; freshly received events must not inherit a preceding long frame.
    @discardableResult
    mutating func advance(seconds: Double, keyboard input: KeyboardInput?) -> Bool {
        let wasVisible = hasLiveStars
        if seconds.isFinite, seconds > 0 { elapsed += seconds }
        bursts.removeAll { elapsed - $0.born >= Self.lifetime }
        if let input, input.sampledAt.isFinite {
            consume(input)
        } else {
            held.removeAll(keepingCapacity: true)
        }
        // At most one repeat per held key per display frame, even after a long stall.
        for code in held.keys.sorted() {
            guard var hold = held[code], elapsed + 1e-9 >= hold.next else { continue }
            emit(hold.key, born: elapsed, small: true)
            hold.next = elapsed + 0.180; held[code] = hold
        }
        present()
        return wasVisible || hasLiveStars
    }

    private mutating func consume(_ input: KeyboardInput) {
        if sessionID != input.sessionID {
            sessionID = input.sessionID; sequence = 0; capsLocked = nil; held.removeAll(keepingCapacity: true)
        }
        guard input.state == .running else {
            held.removeAll(keepingCapacity: true); sequence = input.sequence
            capsLocked = input.modifiers.contains(.capsLock); return
        }
        if input.droppedEventCount > 0 { held.removeAll(keepingCapacity: true) }
        for event in input.events where event.sequence > sequence && event.sequence <= input.sequence {
            sequence = event.sequence
            let age = input.sampledAt - event.receivedAt
            guard age.isFinite, age >= 0, age <= KeyboardChannel.eventLifetime,
                  let key = keys[event.keyCode] else { continue }
            switch event.kind {
            case .pressed:
                guard key.repeats, held[event.keyCode] == nil else { continue }
                emit(key, born: elapsed - age, small: false)
                held[event.keyCode] = Hold(key: key, next: elapsed - age + 0.300)
            case .released:
                held.removeValue(forKey: event.keyCode)
            case .repeated:
                break
            case .modifiersChanged:
                if key == .capsLock {
                    let locked = event.modifierIsPressed ?? event.modifiers.contains(.capsLock)
                    if capsLocked != locked { emit(key, born: elapsed - age, small: false) }
                    capsLocked = locked
                } else if !key.repeats && event.modifierIsPressed == true {
                    emit(key, born: elapsed - age, small: false)
                }
            }
        }
        sequence = max(sequence, input.sequence)
        capsLocked = input.modifiers.contains(.capsLock)
        // A release may have aged out or been dropped. The snapshot is authoritative for stopping holds.
        let stillHeld = Set(input.heldKeys.map(\.keyCode))
        held = held.filter { stillHeld.contains($0.key) }
    }

    private mutating func emit(_ key: StaffKeyboardKey, born: Double, small: Bool) {
        guard StaffKeyboardLayout.positions[key] != nil else { return }
        if bursts.count == Self.burstLimit { bursts.removeFirst() }
        totalBursts &+= 1
        let count = small ? 4 : 6
        // Stable variation per burst, with no random work during presentation.
        let phase = Double(totalBursts % 17) * 0.37
        let particles = (0..<count).map { i in
            let angle = Double(i) * 2 * .pi / Double(count) + phase
            let radius = (3 + Double((i * 7 + Int(totalBursts % 11)) % 5) * 0.5) * (small ? 0.76 : 1)
            let distance = (12 + Double((i * 11 + Int(totalBursts % 13)) % 17)) * (small ? 0.78 : 1)
            return Particle(radius: radius, dx: cos(angle) * distance, dy: sin(angle) * distance,
                rotation: angle * 0.3, spin: i.isMultiple(of: 2) ? 0.7 : -0.6)
        }
        bursts.append(Burst(key: key, born: born, small: small, particles: particles))
    }

    private mutating func present() {
        stars.removeAll(keepingCapacity: true)
        for burst in bursts {
            let age = max(0, elapsed - burst.born), progress = min(1, age / Self.lifetime)
            let origin = StaffKeyboardLayout.positions[burst.key]!
            if age < 0.100 {
                let t = age / 0.100
                stars.append(StaffStar(x: origin.x, y: origin.y,
                    radius: (3.5 + 4.5 * (1 - pow(1 - t, 3))) * (burst.small ? 0.75 : 1),
                    rotation: -0.12 + t * 0.24, opacity: 0.95 * (1 - t)))
            }
            let travel = 1 - pow(1 - progress, 3), opacity = 0.9 * pow(1 - progress, 1.4)
            for p in burst.particles {
                stars.append(StaffStar(x: origin.x + p.dx * travel, y: origin.y + p.dy * travel,
                    radius: p.radius * (0.7 + 0.3 * min(1, age / 0.035)) * (1 - progress * 0.15),
                    rotation: p.rotation + p.spin * progress, opacity: opacity))
            }
        }
    }
}
