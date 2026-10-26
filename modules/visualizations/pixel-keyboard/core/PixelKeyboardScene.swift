import Foundation

/// The keyboard and paws are independent of audio generations and music availability.
struct PixelKeyboardScene {
    struct Key: Sendable {
        let id: StaffKeyboardKey
        let x: Double, y: Double, width: Double
        let label: String
        var centerX: Double { x + width / 2 }
        var isLeft: Bool { centerX < 400 }
    }
    struct Paw: Equatable, Sendable {
        var key: StaffKeyboardKey
        var x: Double, y: Double
        var down = 0.0
    }
    static let width = 800.0, height = 460.0
    static let keys: [Key] = StaffKeyboardLayout.placements.map { placement in
        let rowWidth = 720 + Double(placement.row) * 10
        let unit = rowWidth / 15
        let center = (placement.x - 80) / 680 * rowWidth + (800 - rowWidth) / 2
        let labels: [StaffKeyboardKey: String] = [
            .grave: "`", .digit1: "1", .digit2: "2", .digit3: "3", .digit4: "4", .digit5: "5",
            .digit6: "6", .digit7: "7", .digit8: "8", .digit9: "9", .digit0: "0", .minus: "-", .equal: "=",
            .backspace: "Delete", .tab: "Tab", .capsLock: "Caps", .returnKey: "Return",
            .leftBracket: "[", .rightBracket: "]", .backslash: "\\", .semicolon: ";", .quote: "'",
            .leftShift: "Shift", .rightShift: "Shift", .comma: ",", .period: ".", .slash: "/",
            .function: "Fn", .leftControl: "Ctrl", .rightControl: "Ctrl", .leftOption: "Opt", .rightOption: "Opt",
            .leftCommand: "Cmd", .rightCommand: "Cmd", .space: ""]
        return Key(id: placement.key, x: (center - placement.widthUnits * unit / 2 + 2).rounded(),
                   y: 196 + Double(placement.row) * 38, width: (placement.widthUnits * unit - 4).rounded(),
                   label: labels[placement.key] ?? placement.key.rawValue.uppercased())
    }
    static let positions = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })
    private let codes: [UInt16: StaffKeyboardKey]
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var observed = Set<UInt16>()
    private var flashes = [StaffKeyboardKey: Double]()
    private var elapsed = 0.0
    private var nextSpaceLeft = true
    private(set) var pressed = Set<StaffKeyboardKey>()
    private(set) var left = Paw(key: .f, x: positions[.f]!.centerX, y: positions[.f]!.y + 15)
    private(set) var right = Paw(key: .j, x: positions[.j]!.centerX, y: positions[.j]!.y + 15)
    private(set) var state = KeyboardSourceState.stopped
    init(codes: [UInt16: StaffKeyboardKey]) { self.codes = codes }
    mutating func reset() { self = Self(codes: codes) }
    func isLit(_ key: StaffKeyboardKey) -> Bool { pressed.contains(key) || flashes[key] != nil }
    var litKeys: Set<StaffKeyboardKey> { pressed.union(flashes.keys) }

    @discardableResult
    mutating func advance(seconds: Double, input: KeyboardInput?) -> Bool {
        let beforeLeft = left, beforeRight = right, beforeKeys = litKeys, beforeState = state
        let dt = seconds.isFinite ? max(0, seconds) : 0
        elapsed += dt
        flashes = flashes.filter { $0.value > elapsed }
        if let input, input.sampledAt.isFinite {
            if session != input.sessionID {
                reset(); session = input.sessionID
            }
            state = input.state
            if input.state != .running || input.droppedEventCount > 0 {
                observed.removeAll(); pressed.removeAll(); flashes.removeAll()
            }
            if input.state == .running {
                for event in input.events where event.sequence > sequence && event.sequence <= input.sequence {
                    sequence = event.sequence
                    let age = input.sampledAt - event.receivedAt
                    guard age >= 0, age <= 0.25, let key = codes[event.keyCode] else { continue }
                    switch event.kind {
                    case .pressed:
                        if observed.insert(event.keyCode).inserted { strike(key); pressed.insert(key) }
                    case .released:
                        observed.remove(event.keyCode); pressed.remove(key)
                    case .repeated: break // Held keys remain depressed; OS repeat never queues animations.
                    case .modifiersChanged:
                        if key == .capsLock { strike(key) }
                        else if event.modifierIsPressed == true {
                            observed.insert(event.keyCode); pressed.insert(key); strike(key)
                        } else if event.modifierIsPressed == false {
                            observed.remove(event.keyCode); pressed.remove(key)
                        }
                    }
                }
                let held = Set(input.heldKeys.map(\.keyCode))
                observed = observed.filter { code in
                    guard let key = codes[code] else { return false }
                    if key.repeats { return held.contains(code) }
                    let flag: KeyboardModifiers
                    switch key {
                    case .leftShift, .rightShift: flag = .shift
                    case .leftControl, .rightControl: flag = .control
                    case .leftOption, .rightOption: flag = .option
                    case .leftCommand, .rightCommand: flag = .command
                    case .function: flag = .function
                    default: return false
                    }
                    return input.modifiers.contains(flag)
                }
                pressed = Set(observed.compactMap { codes[$0] })
            }
            sequence = max(sequence, input.sequence)
        } else {
            observed.removeAll(); pressed.removeAll()
        }
        if state != .running {
            left.key = .f; right.key = .j
        }
        let a = 1 - exp(-dt * 38)
        func move(_ paw: inout Paw, lit: Bool) {
            let key = Self.positions[paw.key]!
            let targetY = key.y + 15
            paw.x += (key.centerX - paw.x) * a; paw.y += (targetY - paw.y) * a
            paw.down += ((lit ? 1.0 : 0.0) - paw.down) * a
            if abs(key.centerX - paw.x) < 0.02 { paw.x = key.centerX }
            if abs(targetY - paw.y) < 0.02 { paw.y = targetY }
            if abs((lit ? 1.0 : 0.0) - paw.down) < 0.01 { paw.down = lit ? 1 : 0 }
        }
        move(&left, lit: isLit(left.key)); move(&right, lit: isLit(right.key))
        return left != beforeLeft || right != beforeRight || litKeys != beforeKeys || state != beforeState
    }
    private mutating func strike(_ key: StaffKeyboardKey) {
        guard let position = Self.positions[key] else { return }
        flashes[key] = elapsed + 0.12
        let useLeft = key == .space ? nextSpaceLeft : position.isLeft
        if key == .space { nextSpaceLeft.toggle() }
        if useLeft { left.key = key } else { right.key = key }
    }
}
