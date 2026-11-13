import Foundation

public final class KeyboardSubscription: @unchecked Sendable {
    private let channel: KeyboardChannel
    private let lock = NSLock()
    private var sessionID: UUID
    private var sequence: UInt64

    fileprivate init(channel: KeyboardChannel, sessionID: UUID, sequence: UInt64) {
        self.channel = channel; self.sessionID = sessionID; self.sequence = sequence
    }

    public func read() -> KeyboardInput {
        lock.lock(); defer { lock.unlock() }
        let input = channel.read(sessionID: sessionID, after: sequence)
        sessionID = input.sessionID; sequence = input.sequence
        return input
    }

    public func eventSignals() -> AsyncStream<Void> { channel.eventSignals() }
}

/// Bounded in-memory handoff. A signal wakes the reader, and the channel preserves event order.
public final class KeyboardChannel: KeyboardFeatureSource, @unchecked Sendable {
    public static let eventCapacity = 128
    public static let eventLifetime = 0.250
    public static let rateCapacity = 256
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
    private var eventObservers = [UUID: AsyncStream<Void>.Continuation]()

    public init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func reset(sessionID: UUID, state: KeyboardSourceState) {
        lock.lock()
        self.sessionID = sessionID; self.state = state; sequence = 0
        modifiers = []; held.removeAll(keepingCapacity: true)
        presses.removeAll(keepingCapacity: true); events.removeAll(keepingCapacity: true)
        lastActivity = nil
        unlockAndSignalEvents()
    }

    public func setRunning(sessionID: UUID) {
        lock.lock()
        guard self.sessionID == sessionID, state != .running else { lock.unlock(); return }
        state = .running
        unlockAndSignalEvents()
    }

    @discardableResult
    public func publish(_ event: KeyboardRawEvent, sessionID: UUID) -> Bool {
        lock.lock()
        guard self.sessionID == sessionID, state == .running else {
            lock.unlock()
            return false
        }
        // Sample under the lock, so concurrent callbacks cannot reorder receipt time.
        let time = now()
        guard time.isFinite else {
            lock.unlock()
            return false
        }
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
        unlockAndSignalEvents()
        return true
    }

    private func unlockAndSignalEvents() {
        let observers = eventObservers.values
        lock.unlock()
        for observer in observers { observer.yield() }
    }

    public func subscribe() -> KeyboardSubscription {
        lock.lock(); defer { lock.unlock() }
        return KeyboardSubscription(channel: self, sessionID: sessionID, sequence: sequence)
    }

    fileprivate func eventSignals() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.removeEventObserver(id) }
        lock.lock()
        eventObservers[id] = continuation
        lock.unlock()
        // Include events that arrived between subscribing and registering for wakeups.
        continuation.yield()
        return stream
    }

    private func removeEventObserver(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        eventObservers.removeValue(forKey: id)
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
