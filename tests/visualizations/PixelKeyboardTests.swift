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
        var headID = UUID(), headSeq: UInt64 = 0
        func typing(_ time: Double, rate: Double = 2, kind: KeyboardEventKind? = nil,
                    state: KeyboardSourceState = .running, lag: Double = 0, dropped: UInt64 = 0) -> KeyboardInput {
            var events = [KeyboardInputEvent]()
            if let kind {
                headSeq += 1
                events = [KeyboardInputEvent(sequence:headSeq,receivedAt:time-lag,kind:kind,keyCode:0,modifiers:[],heldDuration:nil)]
            }
            return KeyboardInput(sessionID:headID,sequence:headSeq,state:state,sampledAt:time,modifiers:[],heldKeys:[],
                pressesPerSecond:rate,idleDuration:0,events:events,droppedEventCount:dropped)
        }
        var head = PixelHeadScene()
        head.advance(seconds:0.1,input:typing(0,rate:6))
        check("Existing rate without a fresh press cannot start the head", head.angle == 0)
        head.advance(seconds:0.1,input:typing(0.1,kind:.repeated))
        head.advance(seconds:0.1,input:typing(0.2,kind:.modifiersChanged))
        check("Repeats and modifiers do not trigger head motion", head.amplitude == 0)
        head.advance(seconds:0.1,input:typing(0.3,kind:.pressed,lag:1))
        check("Stale presses do not trigger head motion", head.amplitude == 0)
        head.advance(seconds:1/60,input:typing(1,kind:.pressed))
        head.advance(seconds:0.1,input:typing(1.1))
        check("Fresh typing starts a visible gentle sway", abs(head.angle) > 0.03 && head.amplitude > 0.5)
        let oldPhase = head.phase
        head.advance(seconds:1/60,input:typing(1.12,rate:4,kind:.pressed))
        check("New presses preserve phase rather than restarting each swing", head.phase > oldPhase && head.phase-oldPhase < 0.25)
        var frequencies = [Double](), bounded = true
        for rate in [1,2,4] {
            var sample = PixelHeadScene()
            for frame in 0..<300 {
                let t = Double(frame)/60
                sample.advance(seconds:1/60,input:typing(t,rate:Double(rate),kind:frame%(60/rate)==0 ? .pressed : nil))
                bounded = bounded && abs(sample.angle) <= .pi/15 + 0.00001
            }
            frequencies.append(sample.frequency)
        }
        check("One, two and four presses per second give proportional head frequency", abs(frequencies[1]/frequencies[0]-2)<0.001 && abs(frequencies[2]/frequencies[0]-4)<0.001)
        check("Head tilt stays within twelve degrees at every typing rate", bounded)
        head.advance(seconds:0.01,input:typing(2,state:.secureInput))
        head.advance(seconds:0.01,input:typing(2.01,rate:6))
        check("Secure input stops the head and restore never replays old rate", head.angle == 0 && head.amplitude == 0)
        head.advance(seconds:0.1,input:typing(2.1,kind:.pressed))
        head.advance(seconds:0.1,input:typing(2.2,dropped:1))
        check("Dropped input stops the head until a new press", head.amplitude == 0)
        head.advance(seconds:0.1,input:typing(2.3,kind:.pressed))
        headID = UUID()
        head.advance(seconds:0.1,input:typing(2.4,rate:6))
        check("Keyboard generation changes clear head motion", head.amplitude == 0)
        head.advance(seconds:1/60,input:typing(3,kind:.pressed))
        for i in 1...180 { head.advance(seconds:1/60,input:typing(3+Double(i)/60,rate:0,kind:.repeated)) }
        check("Held-key auto-repeat cannot sustain head motion", head.amplitude == 0 && head.angle == 0)
        head.advance(seconds:1/60,input:typing(7,kind:.pressed))
        for _ in 0..<120 { head.advance(seconds:1/60,input:nil) }
        check("Missing keyboard updates settle without running forever", head.amplitude == 0)
        head.advance(seconds:5,input:typing(12,rate:1000,kind:.pressed))
        check("Long frames start fresh without backlog and excessive rates are capped", head.frequency <= 2.4+0.0001 && head.phase < 0.51)
        head.advance(seconds:.infinity,input:typing(12.1,rate:.nan))
        check("Malformed rate and delta never produce nonfinite transforms", head.angle.isFinite)
        head.reset()
        check("Settled or hidden head requires no redraw", !head.advance(seconds:1/60,input:nil) && head.angle == 0)
        print("PASS \(count) pixel keyboard core checks")
    }
}
