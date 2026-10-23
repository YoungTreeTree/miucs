import Foundation

/// Invented input for exports/probes only. Never posts events to macOS or reads typed content.
@MainActor
final class SyntheticKeyboardInput {
    enum Pattern: String { case demo, typing20, capacity }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = 0.0
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return time }
        func set(_ time: Double) { lock.lock(); self.time = time; lock.unlock() }
    }
    private let clock = Clock()
    private let id = UUID()
    private let pattern: Pattern
    let channel: KeyboardChannel
    private var next = 0.0, index = 0
    private var releases = [(time: Double, key: StaffKeyboardKey)]()
    private(set) var presses = 0
    private(set) var rows = Set<Int>()
    private static let codes = Dictionary(uniqueKeysWithValues: MacStaffKeyboardLayout.keys.map { ($0.value, $0.key) })
    private static let typing: [StaffKeyboardKey] = [.q, .w, .e, .r, .t, .y, .u, .i, .o, .p,
        .a, .s, .d, .f, .g, .h, .j, .k, .l, .space, .z, .x, .c, .v, .b, .n, .m, .returnKey,
        .digit1, .digit5, .digit9, .minus, .backspace, .tab, .quote, .slash]
    private static let demo: [(time: Double, key: StaffKeyboardKey, duration: Double)] = {
        var events = [(Double, StaffKeyboardKey, Double)]()
        let sweep: [StaffKeyboardKey] = [.digit1, .digit4, .digit7, .digit0, .backspace,
            .q, .e, .t, .u, .o, .backslash, .a, .d, .g, .j, .l, .returnKey,
            .z, .c, .b, .m, .slash, .function, .leftCommand, .rightCommand, .rightControl]
        for (i, key) in sweep.enumerated() { events.append((Double(i) * 0.28, key, 0.06)) }
        events += [(2.3, .space, 1.0), (4.4, .a, 0.08), (4.4, .j, 0.08), (4.4, .returnKey, 0.08),
                   (6.1, .leftShift, 0.8), (6.3, .rightShift, 0.5), (7.4, .space, 1.2),
                   (8.0, .q, 0.06), (8.2, .w, 0.06), (8.4, .e, 0.06), (8.6, .r, 0.06),
                   (8.8, .t, 0.06), (9.0, .y, 0.06)]
        return events.sorted { $0.0 < $1.0 }
    }()

    init(_ pattern: Pattern) {
        self.pattern = pattern
        let clock = clock
        channel = KeyboardChannel(now: { clock.read() })
        channel.reset(sessionID: id, state: .running)
    }

    func update(at time: Double) {
        clock.set(time)
        for release in releases where release.time <= time + 1e-9 { send(release.key, down: false) }
        releases.removeAll { $0.time <= time + 1e-9 }
        switch pattern {
        case .typing20:
            if time + 1e-9 >= next {
                press(Self.typing[index % Self.typing.count], time: time, duration: 0.025)
                index += 1; next += 0.050
            }
        case .capacity:
            for key in Self.typing.prefix(16) {
                send(key, down: false); press(key, time: time, duration: 0.01)
            }
        case .demo:
            while index < Self.demo.count, Self.demo[index].time <= time + 1e-9 {
                let event = Self.demo[index]
                press(event.key, time: time, duration: event.duration); index += 1
            }
        }
    }
    private func press(_ key: StaffKeyboardKey, time: Double, duration: Double) {
        send(key, down: true); releases.append((time + duration, key)); presses += 1
        rows.insert(StaffKeyboardLayout.positions[key]!.row)
    }
    private func send(_ key: StaffKeyboardKey, down: Bool) {
        channel.publish(KeyboardRawEvent(kind: key.repeats ? (down ? .pressed : .released) : .modifiersChanged,
            keyCode: Self.codes[key]!, modifiers: [], modifierIsPressed: key.repeats ? nil : down), sessionID: id)
    }
}
