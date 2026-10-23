import Foundation

final class KeyboardSubscription: @unchecked Sendable {
    private let channel: KeyboardChannel
    private let lock = NSLock()
    private var sessionID: UUID
    private var sequence: UInt64

    fileprivate init(channel: KeyboardChannel, sessionID: UUID, sequence: UInt64) {
        self.channel = channel; self.sessionID = sessionID; self.sequence = sequence
    }

    func read() -> KeyboardInput {
        lock.lock(); defer { lock.unlock() }
        let input = channel.read(sessionID: sessionID, after: sequence)
        sessionID = input.sessionID; sequence = input.sequence
        return input
    }
}

/// Bounded in-memory handoff. Capture never calls UI code or queues a task per key.
final class KeyboardChannel: KeyboardFeatureSource, @unchecked Sendable {
    static let eventCapacity = 128
    static let eventLifetime = 0.250
    static let rateCapacity = 256
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var sessionID = UUID()
    private var sequence: UInt64 = 0
    private var state = KeyboardSourceState.stopped
    private var modifiers: KeyboardModifiers = []
    private var held = [UInt16: Double]()
    private var presses = [Double]()
    private var events = [KeyboardInputEvent]()
    private var lastActivity: Double?

    init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func reset(sessionID: UUID, state: KeyboardSourceState) {
        lock.lock(); defer { lock.unlock() }
        self.sessionID = sessionID; self.state = state; sequence = 0
        modifiers = []; held.removeAll(keepingCapacity: true)
        presses.removeAll(keepingCapacity: true); events.removeAll(keepingCapacity: true)
        lastActivity = nil
    }

    func setRunning(sessionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        if self.sessionID == sessionID { state = .running }
    }

    @discardableResult
    func publish(_ event: KeyboardRawEvent, sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.sessionID == sessionID, state == .running else { return false }
        // Sample under the lock, so concurrent callbacks cannot reorder receipt time.
        let time = now()
        guard time.isFinite else { return false }
        prune(at: time)
        var kind = event.kind
        var duration: Double?
        switch kind {
        case .pressed:
            if let start = held[event.keyCode] {
                kind = .repeated; duration = max(0, time - start)
            } else {
                held[event.keyCode] = time
                presses.append(time)
                if presses.count > Self.rateCapacity { presses.removeFirst(presses.count - Self.rateCapacity) }
            }
        case .released:
            duration = held.removeValue(forKey: event.keyCode).map { max(0, time - $0) }
        case .repeated:
            duration = held[event.keyCode].map { max(0, time - $0) }
        case .modifiersChanged:
            break // Modifier transitions never contribute to ordinary held keys or typing rate.
        }
        sequence += 1; modifiers = event.modifiers; lastActivity = time
        events.append(KeyboardInputEvent(sequence: sequence, receivedAt: time, kind: kind,
            keyCode: event.keyCode, modifiers: event.modifiers, heldDuration: duration,
            modifierIsPressed: event.modifierIsPressed))
        if events.count > Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity) }
        return true
    }

    func subscribe() -> KeyboardSubscription {
        lock.lock(); defer { lock.unlock() }
        return KeyboardSubscription(channel: self, sessionID: sessionID, sequence: sequence)
    }

    fileprivate func read(sessionID: UUID, after cursor: UInt64) -> KeyboardInput {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        prune(at: time)
        let after = sessionID == self.sessionID ? cursor : 0
        let unread = events.filter { $0.sequence > after }
        let missing = sequence - after - UInt64(unread.count)
        return KeyboardInput(sessionID: self.sessionID, sequence: sequence, state: state,
            sampledAt: time, modifiers: modifiers,
            heldKeys: held.map { KeyboardHeldKey(keyCode: $0.key, duration: max(0, time - $0.value)) }
                .sorted { $0.keyCode < $1.keyCode },
            pressesPerSecond: Double(presses.count), idleDuration: lastActivity.map { max(0, time - $0) },
            events: unread, droppedEventCount: missing)
    }

    private func prune(at time: Double) {
        events.removeAll { $0.receivedAt < time - Self.eventLifetime }
        presses.removeAll { $0 <= time - 1 }
    }
}
