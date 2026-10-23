import AppKit
import CoreGraphics

private final class FakeKeyboardCapture: KeyboardCaptureSession, @unchecked Sendable {
    let emit: @Sendable (KeyboardRawEvent) -> Void
    let interrupt: @Sendable () -> Void
    private let lock = NSLock()
    private let delayed: Bool
    private let failing: Bool
    private var continuation: CheckedContinuation<Void, Error>?
    private var stopCount = 0
    private var startCount = 0
    init(delayed: Bool, failing: Bool, emit: @escaping @Sendable (KeyboardRawEvent) -> Void,
         interrupt: @escaping @Sendable () -> Void) {
        self.delayed = delayed; self.failing = failing; self.emit = emit; self.interrupt = interrupt
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            lock.lock(); startCount += 1
            if delayed { continuation = pending; lock.unlock() }
            else { lock.unlock(); pending.resume(with: failing ? .failure(KeyboardCaptureError.unavailable) : .success(())) }
        }
    }
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
    func finishStart() {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume()
    }
    var counts: (starts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }; return (startCount, stopCount)
    }
}

private final class KeyboardHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var state = KeyboardEnvironment(permissionGranted: false, secureInput: false)
    private var time = 10.0
    private var captures = [FakeKeyboardCapture]()
    private var delayed = false
    private var failing = false
    private var checkedOnMain = false
    func inspect() -> KeyboardEnvironment {
        lock.lock(); defer { lock.unlock() }
        checkedOnMain = checkedOnMain || Thread.isMainThread
        return state
    }
    func configure(permission: Bool = true, secure: Bool = false, delayed: Bool = false, failing: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        state = KeyboardEnvironment(permissionGranted: permission, secureInput: secure)
        self.delayed = delayed; self.failing = failing
    }
    func make(_ emit: @escaping @Sendable (KeyboardRawEvent) -> Void,
              _ interrupt: @escaping @Sendable () -> Void) -> any KeyboardCaptureSession {
        lock.lock(); defer { lock.unlock() }
        let capture = FakeKeyboardCapture(delayed: delayed, failing: failing, emit: emit, interrupt: interrupt)
        captures.append(capture); return capture
    }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ delta: Double) { lock.lock(); time += delta; lock.unlock() }
    var all: [FakeKeyboardCapture] { lock.lock(); defer { lock.unlock() }; return captures }
    var queriedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return checkedOnMain }
}

@main
@MainActor
enum KeyboardEngineTests {
    static func main() async throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func until(_ predicate: @MainActor () -> Bool) async {
            for _ in 0..<100 {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let harness = KeyboardHarness()
        var permissionRequests = 0
        let engine = KeyboardEngine(factory: { harness.make($0, $1) },
            environment: { await Task.detached { harness.inspect() }.value },
            requestPermission: { permissionRequests += 1; return false }, now: { harness.now() },
            pollInterval: 3600, monitorsSystem: false)
        let reader = engine.channel.subscribe()
        let press = KeyboardRawEvent(kind: .pressed, keyCode: 0, modifiers: [])
        await engine.start()
        check("Missing permission is a distinct state without installing a tap", engine.state == .permissionRequired && harness.all.isEmpty)
        await engine.refresh(); await engine.refresh()
        check("Background permission checks never prompt", permissionRequests == 0)
        await engine.start(requestAccess: true)
        check("Explicit authorization action requests access once", permissionRequests == 1)
        harness.configure(); await engine.refresh()
        let first = harness.all[0]
        check("Granting access starts one capture", engine.state == .running && first.counts.starts == 1)
        await engine.start(); await engine.refresh()
        check("Repeated starts and idle checks do not recreate capture", harness.all.count == 1)
        first.emit(press)
        check("Capture delivers numeric key events", reader.read().events.count == 1)
        harness.configure(permission: false); await engine.refresh()
        let revoked = reader.read()
        check("Permission revocation stops capture and clears held keys", engine.state == .permissionRequired &&
            first.counts.stops > 0 && revoked.heldKeys.isEmpty && revoked.events.isEmpty)
        first.emit(press)
        check("Late events after revocation are discarded", reader.read().events.isEmpty)
        harness.configure(secure: true); await engine.refresh()
        check("Secure input pauses capture without requesting more privileges", engine.state == .secureInput && harness.all.count == 1 && permissionRequests == 1)
        harness.configure(); await engine.refresh()
        let second = harness.all[1]
        second.emit(press); _ = reader.read()
        engine.handleLifecycle(.sleep)
        check("Sleep releases capture and clears held keys", engine.state == .suspended && second.counts.stops > 0 && reader.read().heldKeys.isEmpty)
        engine.handleLifecycle(.sessionInactive); engine.handleLifecycle(.wake)
        await engine.refresh()
        check("Wake cannot resume an inactive login session", engine.state == .suspended && harness.all.count == 2)
        engine.handleLifecycle(.sessionActive)
        await until { engine.state == .running }
        check("Active session resumes a new generation", engine.state == .running && harness.all.count == 3)
        let third = harness.all[2]
        third.emit(press); _ = reader.read(); third.interrupt()
        await until { engine.state == .recovering }
        check("Disabled tap resets pending input before recovery", engine.state == .recovering && reader.read().heldKeys.isEmpty)
        await engine.refresh()
        check("Interrupted taps respect retry delay", harness.all.count == 3)
        harness.advance(1.1); await engine.refresh()
        check("Interrupted tap reconnects automatically on the next health check", engine.state == .running && harness.all.count == 4)
        third.emit(press); third.interrupt(); await Task.yield()
        check("Old callbacks cannot affect the new capture", engine.state == .running && reader.read().events.isEmpty)
        engine.stop(); engine.stop()
        harness.all.last?.emit(press); await engine.refresh()
        check("Stop is idempotent and prevents later revival", engine.state == .stopped && reader.read().events.isEmpty && harness.all.count == 4)
        check("System permission queries execute off the main thread", !harness.queriedMainThread)

        harness.configure(delayed: true)
        let pending = Task { await engine.start() }
        await until { harness.all.count == 5 && harness.all.last?.counts.starts == 1 }
        let stale = harness.all[4]
        engine.stop()
        harness.configure(); await engine.start()
        let newGeneration = reader.read().sessionID
        stale.finishStart(); await pending.value
        stale.emit(press)
        let afterLateStart = reader.read()
        check("Delayed startup cannot replace a newer generation", engine.state == .running &&
            afterLateStart.sessionID == newGeneration && afterLateStart.events.isEmpty && stale.counts.stops > 0)
        engine.stop()
        harness.configure(failing: true); await engine.start()
        let attempts = harness.all.count
        await engine.refresh()
        check("Tap creation failure enters bounded retry", engine.state == .recovering && harness.all.count == attempts)
        harness.configure(); harness.advance(2); await engine.refresh()
        check("Capture creation recovers after a transient failure", engine.state == .running && harness.all.count == attempts + 1)
        engine.stop()

        let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
        event.flags = [.maskShift, .maskCommand, .maskAlphaShift]
        let originalCode = event.getIntegerValueField(.keyboardEventKeycode)
        let decoded = KeyboardEventTap.decode(type: .keyDown, event: event)
        check("Native key-down decoder preserves physical code and modifier flags", decoded?.kind == .pressed && decoded?.keyCode == 12 && decoded?.modifiers == [.shift, .command, .capsLock])
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        check("Native auto-repeat is explicit", KeyboardEventTap.decode(type: .keyDown, event: event)?.kind == .repeated)
        check("Native key-up and modifier transitions are distinct", KeyboardEventTap.decode(type: .keyUp, event: event)?.kind == .released && KeyboardEventTap.decode(type: .flagsChanged, event: event)?.kind == .modifiersChanged)
        check("Mouse events are outside the keyboard channel", KeyboardEventTap.decode(type: .mouseMoved, event: event) == nil)
        check("Decoder does not rewrite keyboard events", event.getIntegerValueField(.keyboardEventKeycode) == originalCode && event.flags == [.maskShift, .maskCommand, .maskAlphaShift])
        event.flags = [.maskControl, .maskAlternate, .maskSecondaryFn]
        check("Control, Option and Fn retain independent modifier bits", KeyboardEventTap.decode(type: .flagsChanged, event: event)?.modifiers == [.control, .option, .function])
        let stopped = KeyboardEventTap(onEvent: { _ in }, onInterruption: {})
        stopped.stop()
        do { try await stopped.start(); check("A stopped native capture cannot install a tap", false) }
        catch { check("A stopped native capture cannot install a tap", true) }

        let pollingHarness = KeyboardHarness()
        var pollingEngine: KeyboardEngine? = KeyboardEngine(factory: { pollingHarness.make($0, $1) },
            environment: { await Task.detached { pollingHarness.inspect() }.value },
            requestPermission: { false }, pollInterval: 0.02, monitorsSystem: false)
        weak var weakEngine = pollingEngine
        await pollingEngine?.start()
        pollingHarness.configure()
        await until { pollingEngine?.state == .running }
        check("Health polling notices permission grants without manual reconnect", pollingEngine?.state == .running)
        pollingHarness.all.last?.emit(press)
        pollingHarness.configure(secure: true)
        await until { pollingEngine?.state == .secureInput }
        check("Entering secure input clears an already held key", pollingEngine?.state == .secureInput &&
            pollingEngine?.channel.subscribe().read().heldKeys.isEmpty == true && pollingHarness.all.last?.counts.stops ?? 0 > 0)
        pollingHarness.configure()
        await until { pollingEngine?.state == .running }
        check("Leaving secure input resumes the independent listener", pollingEngine?.state == .running && pollingHarness.all.count == 2)
        let finalCapture = pollingHarness.all.last
        pollingEngine = nil
        await until { weakEngine == nil }
        check("Releasing an engine cancels polling and stops its native resource", weakEngine == nil && (finalCapture?.counts.stops ?? 0) > 0)

        let failed = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/keyboard-engine-tests.json"))
        if failed > 0 { exit(1) }
    }
}
