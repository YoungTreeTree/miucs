import Foundation

private final class KeyboardTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 10.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

@MainActor
private final class KeyboardProbe: VisualizationSession {
    let descriptor: VisualizationDescriptor
    var keyboard: KeyboardInput?
    var audio: FeatureInput?
    var receivedBeforeUpdate = false
    init(_ id: String) { descriptor = VisualizationDescriptor(id: id, name: id) }
    func activate(viewport: VisualizationViewport) {}
    func resize(to viewport: VisualizationViewport) {}
    func receive(keyboard: KeyboardInput) { self.keyboard = keyboard }
    func update(input: FeatureInput, deltaTime: Double) { audio = input; receivedBeforeUpdate = keyboard != nil }
    func deactivate() {}
    func dispose() {}
}

@main
@MainActor
enum KeyboardChannelTests {
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        let clock = KeyboardTestClock(), id = UUID()
        let channel = KeyboardChannel(now: { clock.read() })
        let a = channel.subscribe(), b = channel.subscribe()
        check("Starts stopped without invented activity", a.read().state == .stopped && a.read().idleDuration == nil)
        channel.reset(sessionID: id, state: .running)
        func emit(_ kind: KeyboardEventKind, _ key: UInt16 = 0, _ modifiers: KeyboardModifiers = []) {
            channel.publish(KeyboardRawEvent(kind: kind, keyCode: key, modifiers: modifiers), sessionID: id)
        }
        emit(.pressed)
        clock.advance(0.05); emit(.repeated)
        let held = a.read()
        check("Held duration advances on the monotonic clock", abs((held.heldKeys.first?.duration ?? 0) - 0.05) < 0.0001)
        check("Auto repeat does not inflate typing rate", held.pressesPerSecond == 1 && held.events.map(\.kind) == [.pressed, .repeated])
        clock.advance(0.05); emit(.released)
        let release = a.read(), all = b.read()
        check("Release has measured hold duration and clears held state", release.heldKeys.isEmpty &&
            abs((release.events.first?.heldDuration ?? 0) - 0.1) < 0.0001)
        check("Readers have independent event cursors", all.events.map(\.kind) == [.pressed, .repeated, .released])
        check("Repeated snapshot reads do not replay events", a.read().events.isEmpty && b.read().events.isEmpty)
        emit(.pressed, 1); emit(.pressed, 1)
        check("Duplicate down is treated as repeat", a.read().events.map(\.kind) == [.pressed, .repeated] && a.read().pressesPerSecond == 2)
        let fresh = channel.subscribe().read()
        check("New reader gets current state without old bursts", fresh.events.isEmpty && fresh.heldKeys.map(\.keyCode) == [1])
        emit(.released, 2)
        check("Orphan release does not invent hold duration", a.read().events.last?.heldDuration == nil)
        emit(.modifiersChanged, 56, [.shift, .command])
        let flags = a.read()
        check("Modifier state is separate from ordinary held keys", flags.modifiers == [.shift, .command] &&
            flags.heldKeys.map(\.keyCode) == [1] && flags.pressesPerSecond == 2)
        channel.publish(KeyboardRawEvent(kind: .modifiersChanged, keyCode: 56, modifiers: [.shift], modifierIsPressed: false), sessionID: id)
        let physicalModifier = a.read()
        let modifierData = try JSONEncoder().encode(physicalModifier)
        let modifierRoundTrip = try JSONDecoder().decode(KeyboardInput.self, from: modifierData)
        check("Optional physical modifier state survives the channel and Codable without changing typing rate",
            modifierRoundTrip.events.last?.modifierIsPressed == false && physicalModifier.pressesPerSecond == 2)
        let legacy = Data(String(data: modifierData, encoding: .utf8)!.replacingOccurrences(of: "\"modifierIsPressed\":false,", with: "")
            .replacingOccurrences(of: ",\"modifierIsPressed\":false", with: "").utf8)
        check("Older v1 events without physical modifier state remain decodable", try JSONDecoder().decode(KeyboardInput.self, from: legacy).events.last?.modifierIsPressed == nil)
        clock.advance(1.1)
        let idle = a.read()
        check("Typing rate decays during idle without new events", idle.pressesPerSecond == 0 && (idle.idleDuration ?? 0) > 1)
        check("Held state survives event expiry", idle.heldKeys.count == 1 && idle.heldKeys[0].duration > 1)
        let expiredReader = channel.subscribe()
        emit(.released, 1); clock.advance(0.3)
        let expired = expiredReader.read()
        check("Expired events are dropped and reported", expired.events.isEmpty && expired.droppedEventCount == 1 && expired.heldKeys.isEmpty)
        let burst = channel.subscribe()
        for _ in 0..<400 { emit(.pressed, 4); emit(.released, 4) }
        let bounded = burst.read()
        check("Event memory is bounded under a burst", bounded.events.count == KeyboardChannel.eventCapacity &&
            bounded.droppedEventCount == UInt64(800 - KeyboardChannel.eventCapacity))
        check("Typing-rate history has a fixed bound", bounded.pressesPerSecond == Double(KeyboardChannel.rateCapacity))
        check("A reader reports each loss only once", burst.read().droppedEventCount == 0)
        emit(.pressed, 9)
        let newID = UUID(); channel.reset(sessionID: newID, state: .suspended)
        let reset = a.read()
        check("Reset clears keys, modifiers, rate, activity and events", reset.sessionID == newID && reset.state == .suspended &&
            reset.heldKeys.isEmpty && reset.modifiers.isEmpty && reset.pressesPerSecond == 0 && reset.idleDuration == nil && reset.events.isEmpty)
        check("Old capture generation cannot publish", !channel.publish(KeyboardRawEvent(kind: .pressed, keyCode: 1, modifiers: []), sessionID: id))
        check("Suspended channel rejects new events", !channel.publish(KeyboardRawEvent(kind: .pressed, keyCode: 1, modifiers: []), sessionID: newID))
        channel.setRunning(sessionID: id)
        check("Late startup cannot revive an old generation", a.read().state == .suspended)
        channel.setRunning(sessionID: newID)
        let concurrent = channel.subscribe()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            channel.publish(KeyboardRawEvent(kind: .pressed, keyCode: UInt16(i), modifiers: []), sessionID: newID)
        }
        let snapshot = concurrent.read()
        check("Concurrent producers preserve ordered unique sequence and held state", snapshot.events.map(\.sequence) == Array(1...64).map(UInt64.init) && snapshot.heldKeys.count == 64)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(KeyboardInput.self, from: encoded)
        check("Value contract round trips without text fields", decoded.sequence == 64 && decoded.events.count == 64 &&
            !(String(data: encoded, encoding: .utf8) ?? "").contains("characters"))

        let audio = FeatureChannel(now: { clock.read() }), audioID = UUID()
        audio.reset(sessionID: audioID, state: .running)
        let registry = VisualizationRegistry()
        let first = KeyboardProbe("first"), second = KeyboardProbe("second")
        registry.register(first.descriptor) { first }; registry.register(second.descriptor) { second }
        let controller = VisualizationController(source: audio, registry: registry, keyboardSource: channel)
        controller.select(id: "first"); controller.resume()
        channel.publish(KeyboardRawEvent(kind: .released, keyCode: 0, modifiers: []), sessionID: newID)
        controller.tick(deltaTime: 1.0 / 60)
        check("One frame delivers both independent sources before animation", first.receivedBeforeUpdate &&
            first.keyboard?.events.count == 1 && first.audio?.state == .running)
        audio.setState(.permissionRequired)
        channel.publish(KeyboardRawEvent(kind: .pressed, keyCode: 0, modifiers: []), sessionID: newID)
        controller.tick(deltaTime: 1.0 / 60)
        check("Audio permission failure does not stop keyboard delivery", first.audio?.state == .permissionRequired && first.keyboard?.events.count == 1)
        controller.pause()
        channel.publish(KeyboardRawEvent(kind: .released, keyCode: 0, modifiers: []), sessionID: newID)
        controller.resume(); controller.tick(deltaTime: 1.0 / 60)
        check("Resume reads held state without replaying hidden events", first.keyboard?.events.isEmpty == true &&
            first.keyboard?.heldKeys.contains(where: { $0.keyCode == 0 }) == false)
        controller.select(id: "second"); controller.tick(deltaTime: 1.0 / 60)
        check("Switching modules does not reset or replay either source", second.keyboard?.sessionID == newID && second.keyboard?.events.isEmpty == true && second.audio?.sessionID == audioID)
        channel.reset(sessionID: UUID(), state: .permissionRequired)
        audio.setState(.running); controller.tick(deltaTime: 1.0 / 60)
        check("Keyboard permission failure does not stop audio delivery", second.keyboard?.state == .permissionRequired && second.audio?.state == .running)
        controller.dispose()

        let failed = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/keyboard-channel-tests.json"))
        if failed > 0 { exit(1) }
    }
}
