import Foundation

@main enum PixelKeyboardTests {
    static func main() {
        var count = 0
        func check(_ name: String, _ ok: Bool) { count += 1; if !ok { FileHandle.standardError.write(Data("FAIL \(name)\n".utf8)); exit(1) }; print("PASS \(name)") }
        let codes: [UInt16: StaffKeyboardKey] = [0:.a, 1:.j, 2:.space, 3:.leftShift, 4:.rightShift, 5:.capsLock]
        var scene = PixelKeyboardScene(codes: codes), generation = UUID(), seq: UInt64 = 0
        func event(_ code: UInt16, _ kind: KeyboardEventKind, time: Double, down: Bool? = nil) -> KeyboardInputEvent {
            seq += 1
            return KeyboardInputEvent(sequence: seq, receivedAt: time, kind: kind, keyCode: code, modifiers: [], heldDuration: nil, modifierIsPressed: down)
        }
        func input(_ events: [KeyboardInputEvent] = [], now: Double = 1, held: [UInt16] = [],
                   state: KeyboardSourceState = .running, flags: KeyboardModifiers = [], dropped: UInt64 = 0) -> KeyboardInput {
            KeyboardInput(sessionID: generation, sequence: seq, state: state, sampledAt: now, modifiers: flags,
                heldKeys: held.map { KeyboardHeldKey(keyCode: $0, duration: 0) }, pressesPerSecond: 0, idleDuration: nil,
                events: events, droppedEventCount: dropped)
        }
        check("All physical main-area keys have unique bounded geometry", Set(PixelKeyboardScene.keys.map(\.id)).count == StaffKeyboardKey.allCases.count &&
            PixelKeyboardScene.keys.allSatisfy { $0.x >= 0 && $0.x+$0.width <= 800 && $0.y+34 < 420 })
        check("Readable punctuation and real wide keys", PixelKeyboardScene.positions[.period]?.label == "." &&
            PixelKeyboardScene.positions[.space]!.width > PixelKeyboardScene.positions[.a]!.width * 6)
        let pair = [event(0,.pressed,time:1),event(1,.pressed,time:1)]
        scene.advance(seconds: 1/60, input: input(pair,held:[0,1]))
        check("Simultaneous left and right keys light and target both paws", scene.isLit(.a) && scene.isLit(.j) && scene.left.key == .a && scene.right.key == .j)
        scene.advance(seconds: 1, input: input(now:2,held:[0,1]))
        check("Holding keeps the actual keys depressed", scene.pressed == [.a,.j])
        scene.advance(seconds: 0.01, input: input([event(0,.released,time:2),event(1,.released,time:2)],now:2))
        scene.advance(seconds: 1, input: input(now:3))
        check("Release clears key and paw depression", scene.litKeys.isEmpty && scene.left.down == 0 && scene.right.down == 0)
        for _ in 0..<120 { scene.advance(seconds:1/60,input:input(now:3)) }
        check("Settled keyboard requires no further redraw", !scene.advance(seconds:1/60,input:input(now:3)))
        scene.advance(seconds:0.01,input:input([event(2,.pressed,time:3),event(2,.released,time:3)],now:3))
        check("Short taps remain briefly visible even in the same frame", scene.isLit(.space) && scene.left.key == .space)
        scene.advance(seconds:0.2,input:input([event(2,.pressed,time:3.2),event(2,.released,time:3.2)],now:3.2))
        check("Space alternates paws", scene.right.key == .space)
        scene.advance(seconds:0.01,input:input([event(3,.modifiersChanged,time:4,down:true),event(4,.modifiersChanged,time:4,down:true)],now:4,flags:.shift))
        scene.advance(seconds:0.3,input:input([event(3,.modifiersChanged,time:4.3,down:false)],now:4.3,flags:.shift))
        check("Left modifier release preserves the right-side hold", !scene.isLit(.leftShift) && scene.isLit(.rightShift))
        scene.advance(seconds:0.01,input:input(now:4.4,state:.secureInput))
        check("Secure input clears all pressed visuals", scene.litKeys.isEmpty)
        scene.advance(seconds:0.01,input:input(now:4.5,held:[0,1]))
        check("Restoring permissions never replays held keys", scene.litKeys.isEmpty)
        scene.advance(seconds:0.01,input:input([event(0,.pressed,time:5)],now:5,held:[0]))
        scene.advance(seconds:0.01,input:input(now:5.1,held:[0],dropped:3))
        check("Dropped release events cannot strand pressed keys", scene.litKeys.isEmpty)
        generation = UUID(); seq = 0
        scene.advance(seconds:2,input:input([event(0,.pressed,time:1)],now:6,held:[0]))
        check("New generation and long frames never replay old presses", scene.litKeys.isEmpty)
        scene.advance(seconds:0.01,input:input([event(99,.pressed,time:6)],now:6,held:[99]))
        check("Unknown physical keys are ignored", scene.litKeys.isEmpty)
        scene.advance(seconds:0.01,input:input([event(0,.repeated,time:6)],now:6,held:[0]))
        check("System repeat cannot start a missing press", scene.litKeys.isEmpty)
        scene.reset()
        check("Hide clears cursors and returns both paws home", scene.left.key == .f && scene.right.key == .j && scene.litKeys.isEmpty)
        check("Pixel grid has a fixed size and a bounded palette", PixelPawSprite.rows.count == 32 && PixelPawSprite.rows.allSatisfy { $0.count == 22 && $0.allSatisfy { "012345".contains($0) } })
        print("PASS \(count) pixel keyboard core checks")
    }
}
