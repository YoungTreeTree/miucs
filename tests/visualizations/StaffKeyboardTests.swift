import Foundation

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ dt: Double) { lock.lock(); value += dt; lock.unlock() }
}

@MainActor
private final class KeyboardRig {
    static let keys = Dictionary(uniqueKeysWithValues: StaffKeyboardKey.allCases.enumerated().map { (UInt16($0.offset), $0.element) })
    static func code(_ key: StaffKeyboardKey) -> UInt16 { keys.first { $0.value == key }!.key }
    let clock = TestClock()
    let channel: KeyboardChannel
    let reader: KeyboardSubscription
    var id = UUID()
    var stars = StaffKeyboardStars(keys: keys)
    init() {
        let clock = clock
        channel = KeyboardChannel(now: { clock.read() })
        channel.reset(sessionID: id, state: .running); reader = channel.subscribe()
    }
    func emit(_ key: StaffKeyboardKey, _ kind: KeyboardEventKind = .pressed, down: Bool? = nil) {
        channel.publish(KeyboardRawEvent(kind: kind, keyCode: Self.code(key),
            modifiers: key == .capsLock && down == true ? [.capsLock] : [], modifierIsPressed: down), sessionID: id)
    }
    @discardableResult func step(_ dt: Double = 0) -> Bool {
        clock.advance(dt); return stars.advance(seconds: dt, keyboard: reader.read())
    }
    func transition(_ state: KeyboardSourceState) {
        id = UUID(); channel.reset(sessionID: id, state: state)
    }
}

@main
@MainActor
enum StaffKeyboardTests {
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }
        let layout = StaffKeyboardLayout.placements, pos = StaffKeyboardLayout.positions
        check("Every main-section physical key has one placement", Set(layout.map(\.key)) == Set(StaffKeyboardKey.allCases) && layout.count == 61)
        check("All five rows span exactly 15 units at the specified heights", (0..<5).allSatisfy { row in
            let keys = layout.filter { $0.row == row }
            return near(keys.reduce(0) { $0 + $1.widthUnits }, 15) && keys.allSatisfy { $0.y == 36 + Double(row) * 22 }
        })
        check("Q A Z preserve ANSI row staggering", near(pos[.q]!.x - pos[.digit1]!.x, 680 / 30) &&
            near(pos[.a]!.x - pos[.q]!.x, 680 / 60) && near(pos[.z]!.x - pos[.a]!.x, 680 / 30))
        check("Wide keys use their centers rather than the left key position", near(pos[.backspace]!.x, 80 + 14 * 680 / 15) &&
            near(pos[.returnKey]!.x, 709) && near(pos[.tab]!.x, 114))
        let bottom = layout.filter { $0.row == 4 }
        check("Bottom row includes both modifier sides and the 6.25-unit space", bottom.map(\.key) ==
            [.function, .leftControl, .leftOption, .leftCommand, .space, .rightCommand, .rightOption, .rightControl] &&
            bottom.allSatisfy { $0.widthUnits == ($0.key == .space ? 6.25 : 1.25) } && near(pos[.space]!.x, 448.3333333333333))

        let tap = KeyboardRig(); tap.emit(.q); tap.step()
        check("A fresh press produces a center and six stars in the same update", tap.stars.totalBursts == 1 && tap.stars.stars.count == 7 &&
            tap.stars.stars.allSatisfy { $0.x == pos[.q]!.x && $0.y == pos[.q]!.y })
        tap.emit(.q, .released); tap.step(0.04)
        let central = tap.stars.stars[0]
        check("The center rapidly grows while six stars spread in different directions", central.radius > 6 && central.opacity < 0.6 &&
            tap.stars.stars.dropFirst().allSatisfy { hypot($0.x - pos[.q]!.x, $0.y - pos[.q]!.y) > 1 })
        tap.step(0.061)
        check("The center is gone after 100ms, while the six satellites remain", tap.stars.stars.count == 6)
        check("The final expiration requests one redraw to remove stale stars", tap.step(0.55) && tap.stars.stars.isEmpty)
        check("An idle scene stops requesting keyboard redraws", !tap.step(1))

        let chord = KeyboardRig()
        for key in [StaffKeyboardKey.a, .j, .space] { chord.emit(key) }
        chord.step()
        check("Simultaneous keys burst at three independent physical positions", chord.stars.totalBursts == 3 && chord.stars.stars.count == 21 &&
            Set(chord.stars.stars.map(\.x)) == Set([pos[.a]!.x, pos[.j]!.x, pos[.space]!.x]))
        let hold = KeyboardRig(); hold.emit(.a); hold.step()
        hold.step(0.299)
        check("Holding does not repeat before 300ms", hold.stars.totalBursts == 1)
        hold.step(0.001)
        check("Holding at 300ms adds one smaller center and four stars", hold.stars.totalBursts == 2 && hold.stars.stars.count == 11 &&
            hold.stars.stars.suffix(5).allSatisfy { $0.radius < 4 })
        hold.step(0.179); let before = hold.stars.totalBursts; hold.step(0.001)
        check("Subsequent repeat interval is 180ms", before == 2 && hold.stars.totalBursts == 3)
        for _ in 0..<20 { hold.emit(.a, .repeated) }
        hold.step()
        check("OS auto-repeat events do not add bursts or change the application rhythm", hold.stars.totalBursts == 3)
        hold.emit(.a, .released); hold.step(); hold.step(0.8)
        check("Release immediately stops births, and existing particles expire naturally", hold.stars.totalBursts == 3 && !hold.stars.hasLiveStars)
        let releaseLost = KeyboardRig(); releaseLost.emit(.a); releaseLost.step()
        releaseLost.emit(.a, .released); releaseLost.step(0.4)
        check("Snapshot cancels a hold even if its release event has aged out", releaseLost.stars.totalBursts == 1)

        let modifiers = KeyboardRig()
        for key in [StaffKeyboardKey.leftShift, .rightShift, .leftCommand, .rightCommand, .function] {
            modifiers.emit(key, .modifiersChanged, down: true)
        }
        modifiers.step(); let modifierCount = modifiers.stars.totalBursts
        for key in [StaffKeyboardKey.leftShift, .rightShift, .leftCommand, .rightCommand, .function] {
            modifiers.emit(key, .modifiersChanged, down: false)
        }
        modifiers.step(); modifiers.step(1)
        check("Modifier sides each burst once; releases and holds never repeat", modifierCount == 5 && modifiers.stars.totalBursts == 5)
        modifiers.emit(.leftOption, .modifiersChanged); modifiers.step()
        check("Unresolved modifier transitions are ignored", modifiers.stars.totalBursts == 5)
        modifiers.emit(.capsLock, .modifiersChanged, down: true); modifiers.step()
        modifiers.emit(.capsLock, .modifiersChanged, down: true); modifiers.step()
        modifiers.emit(.capsLock, .modifiersChanged, down: false); modifiers.step()
        check("Caps Lock bursts on both toggles but not duplicate lock states", modifiers.stars.totalBursts == 7)
        let unknown = KeyboardRig()
        unknown.channel.publish(KeyboardRawEvent(kind: .pressed, keyCode: 999, modifiers: []), sessionID: unknown.id)
        unknown.step()
        check("Keys outside the physical layout do not create particles", unknown.stars.stars.isEmpty)

        let repeatOnly = KeyboardRig(); repeatOnly.emit(.a, .repeated); repeatOnly.step(); repeatOnly.step(1)
        check("Listening midway through a hold never starts synthetic repeats", repeatOnly.stars.totalBursts == 0)
        let duplicate = KeyboardRig(); duplicate.emit(.q)
        let snapshot = duplicate.reader.read()
        duplicate.stars.advance(seconds: 0, keyboard: snapshot)
        duplicate.stars.advance(seconds: 0, keyboard: snapshot)
        check("Event sequence cursor makes replaying a snapshot idempotent", duplicate.stars.totalBursts == 1)
        let generation = KeyboardRig(); generation.emit(.z); generation.step(); generation.step(0.05)
        generation.transition(.secureInput); generation.step(0.01)
        let retained = generation.stars.hasLiveStars
        generation.channel.setRunning(sessionID: generation.id); generation.step(0.8)
        check("Secure input preserves fading stars but cancels all holds across recovery", retained && generation.stars.totalBursts == 1 && !generation.stars.hasLiveStars)
        generation.emit(.z); generation.step()
        check("Recovery responds to fresh presses in the new generation", generation.stars.totalBursts == 2)
        var unavailableSafe = true
        for state in [KeyboardSourceState.permissionRequired, .suspended, .recovering, .stopped, .connecting] {
            let rig = KeyboardRig(); rig.emit(.q); rig.step(); rig.transition(state); rig.step(0.02); rig.step(1)
            unavailableSafe = unavailableSafe && rig.stars.totalBursts == 1 && !rig.stars.hasLiveStars
        }
        check("Permission loss, suspend, stop and reconnect cannot replay held keys", unavailableSafe)
        let stalled = KeyboardRig(); stalled.emit(.space); stalled.step(); stalled.step(5)
        check("A long frame expires old particles and emits at most one current repeat", stalled.stars.totalBursts == 2 && stalled.stars.burstCount == 1 && stalled.stars.stars.count == 5)
        stalled.clock.advance(2); stalled.emit(.q)
        stalled.stars.advance(seconds: 2, keyboard: stalled.reader.read())
        check("A fresh event after a stall is not aged by the preceding frame duration", stalled.stars.stars.contains { $0.x == pos[.q]!.x && $0.y == pos[.q]!.y && $0.opacity > 0.9 })
        let bounded = KeyboardRig()
        for key in StaffKeyboardKey.allCases {
            bounded.emit(key, key.repeats ? .pressed : .modifiersChanged, down: true)
        }
        bounded.step()
        check("Capacity recycles oldest bursts and never exceeds 16 bursts / 112 stars", bounded.stars.burstCount == 16 && bounded.stars.stars.count == 112 &&
            !bounded.stars.stars.contains { $0.y == 36 })
        var inside = true
        for key in StaffKeyboardKey.allCases {
            let rig = KeyboardRig(); rig.emit(key, key.repeats ? .pressed : .modifiersChanged, down: true); rig.step()
            rig.emit(key, .released)
            for _ in 0..<40 {
                rig.step(1.0 / 60)
                inside = inside && rig.stars.stars.allSatisfy {
                    $0.x - $0.radius - 1.5 > 0 && $0.x + $0.radius + 1.5 < 800 &&
                    $0.y - $0.radius - 1.5 > 0 && $0.y + $0.radius + 1.5 < 160
                }
            }
        }
        check("All main-section bursts fit the canvas throughout their lifetime", inside)

        let sim = StaffNoteSimulation(keyboardKeys: KeyboardRig.keys), simKeys = KeyboardRig()
        let viewport = VisualizationViewport(width: 800, height: 160, scale: 1)
        sim.activate(viewport: viewport)
        var audioID = UUID()
        func noAudio(_ state: AudioSourceState = .permissionRequired) -> FeatureInput {
            FeatureInput(sessionID: audioID, state: state, frame: nil, frameAge: nil, onsets: [], spectralFluxPeak: 0)
        }
        simKeys.emit(.a); sim.receive(keyboard: simKeys.reader.read()); sim.update(input: noAudio(), deltaTime: 1.0 / 60)
        check("The native session pipeline animates keyboard input without audio permission", sim.needsDisplay && sim.keyboardStars.stars.count == 7 && sim.scene.pitch == nil)
        audioID = UUID(); simKeys.clock.advance(0.05)
        sim.receive(keyboard: simKeys.reader.read()); sim.update(input: noAudio(.recovering), deltaTime: 0.05)
        check("Audio generation changes do not reset keyboard particles or hold rhythm", sim.keyboardStars.totalBursts == 1 && sim.keyboardStars.hasLiveStars)
        simKeys.clock.advance(0.25); sim.receive(keyboard: simKeys.reader.read()); sim.update(input: noAudio(), deltaTime: 0.25)
        check("Keyboard repeat continues independently through audio reconnection", sim.keyboardStars.totalBursts == 2)
        sim.deactivate()
        check("Hiding or disposing the module clears every burst", sim.keyboardStars.stars.isEmpty && !sim.keyboardStars.hasLiveStars)
        sim.activate(viewport: viewport)
        let resubscribed = simKeys.channel.subscribe()
        sim.receive(keyboard: resubscribed.read()); sim.update(input: noAudio(), deltaTime: 1)
        check("Resume with a held snapshot does not replay a hidden press", sim.keyboardStars.totalBursts == 0)
        for _ in 0..<120 { sim.update(input: noAudio(), deltaTime: 1.0 / 60) }
        check("Settled audio and no stars stop display invalidation", !sim.needsDisplay)

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/staff-keyboard-tests.json"))
        if failures > 0 { exit(1) }
    }
}
