import Foundation

/// Typing controls the portrait independently of music. The channel's rate excludes
/// OS repeats and modifiers; a fresh physical press must arm motion after any reset.
struct TrayHeadAnimation {
    private(set) var frequency = 0.0
    private(set) var amplitude = 0.0
    private(set) var phase = 0.0
    var angle: Double { amplitude * sin(phase) * .pi / 15 }
    private var session: UUID?
    private var cursor: UInt64 = 0
    private var sampleTime: Double?
    private var sinceInput = 100.0, sincePress = 100.0, rate = 0.0
    private var armed = false

    mutating func reset() { self = TrayHeadAnimation() }

    @discardableResult
    mutating func advance(seconds: Double, input: KeyboardInput?) -> Bool {
        let previous = angle
        let dt = seconds.isFinite ? max(0, seconds) : 0
        sinceInput += dt; sincePress += dt
        var freshPress = false
        if let input {
            if session != input.sessionID { reset(); session = input.sessionID }
            if input.state != .running || input.droppedEventCount > 0 || !input.sampledAt.isFinite ||
                sampleTime.map({ input.sampledAt < $0 }) == true {
                reset(); session = input.sessionID; cursor = input.sequence
                return abs(previous - angle) > 0.00001
            }
            if sampleTime == nil || input.sampledAt > sampleTime! {
                sinceInput = 0; sampleTime = input.sampledAt
                rate = input.pressesPerSecond.isFinite ? min(6, max(0, input.pressesPerSecond)) : 0
            }
            for event in input.events where event.sequence > cursor && event.sequence <= input.sequence {
                let age = input.sampledAt - event.receivedAt
                if event.kind == .pressed && age.isFinite && age >= 0 && age <= 0.25 {
                    freshPress = true; armed = true; sincePress = age
                }
            }
            cursor = max(cursor, input.sequence)
        }
        let active = armed && sinceInput <= 0.25 && rate > 0 &&
            sincePress <= max(0.45, min(1.25, 1.5 / max(rate, 1)))
        // A stalled frame never replays a backlog or leaps through a new gesture.
        let step = freshPress ? min(dt, 1.0 / 30) : dt
        let targetFrequency = 0.4 * rate
        if active {
            if amplitude == 0 { frequency = targetFrequency }
            frequency += (targetFrequency - frequency) * (1 - exp(-step / 0.18))
        }
        amplitude += ((active ? 1.0 : 0.0) - amplitude) * (1 - exp(-step / (active ? 0.12 : 0.18)))
        if !active && amplitude < 0.002 {
            amplitude = 0; frequency = 0; phase = 0; armed = false
        } else {
            phase = (phase + 2 * .pi * frequency * step).truncatingRemainder(dividingBy: 2 * .pi)
        }
        return abs(previous - angle) > 0.00001
    }
}
