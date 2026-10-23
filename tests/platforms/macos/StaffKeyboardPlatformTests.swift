import AppKit
import Carbon

@main
@MainActor
enum StaffKeyboardPlatformTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        let map = MacStaffKeyboardLayout.keys
        check("Native ANSI mapping covers the entire portable layout exactly once", Set(map.values) == Set(StaffKeyboardKey.allCases) && map.count == 61)
        check("Physical mapping includes both sides and ignores function, navigation and keypad keys", map[0] == .a && map[12] == .q && map[49] == .space &&
            map[56] == .leftShift && map[60] == .rightShift && map[55] == .leftCommand && map[54] == .rightCommand &&
            [UInt16(kVK_F1), UInt16(kVK_LeftArrow), UInt16(kVK_Home), UInt16(kVK_ANSI_Keypad0)].allSatisfy { map[$0] == nil })
        var sidesCorrect = true
        for (left, right, lMask, rMask, aggregate) in [
            (kVK_Shift, kVK_RightShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK, CGEventFlags.maskShift),
            (kVK_Control, kVK_RightControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK, .maskControl),
            (kVK_Option, kVK_RightOption, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK, .maskAlternate),
            (kVK_Command, kVK_RightCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK, .maskCommand)
        ] {
            for (code, mask, otherMask) in [(left, lMask, rMask), (right, rMask, lMask)] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(code), keyDown: true)!
                event.flags = CGEventFlags(rawValue: aggregate.rawValue | UInt64(mask) | UInt64(otherMask))
                sidesCorrect = sidesCorrect && KeyboardEventTap.decode(type: .flagsChanged, event: event)?.modifierIsPressed == true
                event.flags = CGEventFlags(rawValue: aggregate.rawValue | UInt64(otherMask))
                sidesCorrect = sidesCorrect && KeyboardEventTap.decode(type: .flagsChanged, event: event)?.modifierIsPressed == false
                event.flags = []
                sidesCorrect = sidesCorrect && KeyboardEventTap.decode(type: .flagsChanged, event: event)?.modifierIsPressed == false
                event.flags = aggregate
                sidesCorrect = sidesCorrect && KeyboardEventTap.decode(type: .flagsChanged, event: event)?.modifierIsPressed == nil
            }
        }
        check("Every left/right modifier decoder distinguishes press from release with the opposite side held", sidesCorrect)
        let fn = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Function), keyDown: true)!
        fn.flags = .maskSecondaryFn
        let fnDown = KeyboardEventTap.decode(type: .flagsChanged, event: fn)?.modifierIsPressed == true
        fn.flags = []
        check("Fn uses its dedicated down/up flag", fnDown && KeyboardEventTap.decode(type: .flagsChanged, event: fn)?.modifierIsPressed == false)
        let caps = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_CapsLock), keyDown: true)!
        caps.flags = .maskAlphaShift
        let locked = KeyboardEventTap.decode(type: .flagsChanged, event: caps)?.modifierIsPressed == true
        caps.flags = []
        check("Caps Lock transports both lock states as modifiersChanged", locked && KeyboardEventTap.decode(type: .flagsChanged, event: caps)?.modifierIsPressed == false)

        let view = StaffNoteView(), scene = StaffNotePreview.sampleScene(midi: 71)
        view.wantsLayer = true
        let shape = StaffStar(x: 300, y: 124, radius: 5, rotation: 0, opacity: 1)
        view.updatePreview(scene, stars: [shape]); view.updateLayer()
        let root = view.layer!.sublayers!.first!, starLayer = root.sublayers!.first { $0.name == "keyboard-stars" }!
        let pool = starLayer.sublayers!, identities = pool.map(ObjectIdentifier.init)
        let starIndex = root.sublayers!.firstIndex(of: starLayer)!, noteIndex = root.sublayers!.firstIndex { $0.name == "music-note" }!
        let trailIndex = root.sublayers!.firstIndex { $0.name == "melody-trail" }!
        let textIndices = root.sublayers!.indices.filter { root.sublayers![$0] is CATextLayer }
        check("Stars sit above the staff/trail and below the note and text layers", trailIndex < starIndex &&
            starIndex < noteIndex && textIndices.count == 2 && textIndices.allSatisfy { $0 > starIndex })
        check("The retained pool allocates exactly 112 two-stroke vector stars", pool.count == 112 && pool.allSatisfy { $0.sublayers?.count == 2 && $0.sublayers!.allSatisfy { $0 is CAShapeLayer } })
        let path = (pool[0].sublayers![0] as! CAShapeLayer).path!
        var lines = 0, moves = 0, closures = 0
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint: moves += 1
            case .addLineToPoint: lines += 1
            case .closeSubpath: closures += 1
            default: break
            }
        }
        check("Cached star geometry is a closed ten-vertex five-point outline", moves == 1 && lines == 9 && closures == 1 &&
            pool.allSatisfy { ($0.sublayers![0] as! CAShapeLayer).path == path })
        for tick in 0..<160 {
            let count = tick % 113
            view.updatePreview(scene, stars: (0..<count).map { i in
                StaffStar(x: Double(i) * 5 + 80, y: 80, radius: 3 + Double(i % 3), rotation: Double(tick) / 100, opacity: 0.8)
            }); view.updateLayer()
        }
        check("Saturated animation reuses all pool objects and the cached path", starLayer.sublayers!.map(ObjectIdentifier.init) == identities &&
            (pool[0].sublayers![0] as! CAShapeLayer).path === path)
        view.updatePreview(scene); view.updateLayer()
        check("Expired particles hide their old layers without removing the pool", pool.allSatisfy(\.isHidden))
        var uniform = true
        for width in [600.0, 800, 1600] {
            view.setFrameSize(NSSize(width: width, height: width / 5))
            view.updatePreview(scene, stars: [StaffStar(x: 300, y: 124, radius: 4, rotation: 0.63, opacity: 1)]); view.updateLayer()
            let global = root.affineTransform(), local = pool[0].affineTransform()
            uniform = uniform && abs(global.a - width / 800) < 1e-8 && global.a == global.d &&
                abs(hypot(local.a, local.b) - hypot(local.c, local.d)) < 1e-8 && abs(local.a * local.c + local.b * local.d) < 1e-8
        }
        check("600/800/1600-point windows scale position and star geometry uniformly", uniform)

        let directory = URL(fileURLWithPath: "build/staff-keyboard-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var distinct = Set<Data>(), colorsVisible = true, emptyCenters = true
        for ink in VisualizationInk.allCases {
            let bitmap = StaffNotePreview.bitmap(scene: scene, width: 800, retainedLayers: true, stars: [shape], appearance: ink.appearance)
            var matching = 0
            for y in 236..<260 {
                for x in 588..<612 {
                    let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if c.alphaComponent > 0.8 && abs(c.redComponent - ink.color.red) < 0.1 &&
                        abs(c.greenComponent - ink.color.green) < 0.1 && abs(c.blueComponent - ink.color.blue) < 0.1 { matching += 1 }
                }
            }
            colorsVisible = colorsVisible && matching > 10
            emptyCenters = emptyCenters && bitmap.colorAt(x: 600, y: 248)!.alphaComponent == 0
            let data = bitmap.representation(using: .png, properties: [:])!
            distinct.insert(data); try data.write(to: directory.appendingPathComponent("ink-\(ink.id).png"))
        }
        check("All five global ink colors reach the stars' native strokes", colorsVisible && distinct.count == 5)
        check("Stars retain transparent interiors without glow or a keyboard background", emptyCenters)

        let keyboardID = UUID()
        let previewKeys: [StaffKeyboardKey] = [.grave, .backspace, .q, .returnKey, .leftShift, .rightShift, .function, .rightControl]
        let events = previewKeys.enumerated().map { i, key in
            KeyboardInputEvent(sequence: UInt64(i + 1), receivedAt: 0, kind: key.repeats ? .pressed : .modifiersChanged,
                keyCode: map.first { $0.value == key }!.key, modifiers: [], heldDuration: nil, modifierIsPressed: true)
        }
        var stars = StaffKeyboardStars(keys: map)
        stars.advance(seconds: 0, keyboard: KeyboardInput(sessionID: keyboardID, sequence: UInt64(events.count), state: .running,
            sampledAt: 0, modifiers: [], heldKeys: [], pressesPerSecond: 0, idleDuration: 0, events: events, droppedEventCount: 0))
        stars.advance(seconds: 0.08, keyboard: nil)
        var backgroundsVisible = true, edgesClear = true
        for width in [600, 800, 1600] {
            for (name, background) in [("light", NSColor(calibratedWhite: 0.96, alpha: 1)), ("dark", NSColor(calibratedWhite: 0.12, alpha: 1))] {
                let b = StaffNotePreview.bitmap(scene: scene, width: width, background: background, retainedLayers: true, stars: stars.stars)
                let baseline = StaffNotePreview.bitmap(scene: scene, width: width, background: background, retainedLayers: true)
                var changed = 0
                for y in 0..<b.pixelsHigh {
                    for x in 0..<b.pixelsWide where !b.colorAt(x: x, y: y)!.isEqual(baseline.colorAt(x: x, y: y)!) {
                        changed += 1
                        if x < 2 || y < 2 || x >= b.pixelsWide - 2 || y >= b.pixelsHigh - 2 { edgesClear = false }
                    }
                }
                backgroundsVisible = backgroundsVisible && changed > 250
                try b.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("stars-\(width)-\(name).png"))
            }
        }
        check("Native bursts are visible on light/dark backgrounds at all three sizes", backgroundsVisible)
        check("The six rendered size/background combinations do not clip any particles", edgesClear)
        let overlap = [StaffStar(x: scene.noteCenterX, y: scene.noteY, radius: 7, rotation: 0.7, opacity: 1)]
        let plain = StaffNotePreview.bitmap(scene: scene, width: 800, retainedLayers: true)
        let covered = StaffNotePreview.bitmap(scene: scene, width: 800, retainedLayers: true, stars: overlap)
        check("The solid note head stays readable when stars pass beneath it", plain.colorAt(x: 1280, y: 148)!.isEqual(covered.colorAt(x: 1280, y: 148)!))

        let session = MacStaffNoteSession(), baseline = MacStaffNoteSession()
        let viewport = VisualizationViewport(width: 800, height: 160, scale: 1), audioID = UUID()
        session.activate(viewport: viewport); baseline.activate(viewport: viewport)
        var keySequence: UInt64 = 0, maxAngle = 0.0, minScale = 10.0, maxScale = 0.0, paired = true
        for tick in 0..<120 {
            let time = Double(tick) / 60
            var audio = StaffNotePreview.audio(time); audio.envelope = tick % 40 < 20 ? 0.015 : 0.22
            let frame = AudioFeatureFrame(sessionID: audioID, sequence: UInt64(tick + 1), receivedAt: time,
                audio: audio, melody: StaffNotePreview.melody(time, midi: tick < 60 ? 67 : 69))
            let input = FeatureInput(sessionID: audioID, state: .running, frame: frame, frameAge: 0,
                onsets: tick % 20 == 0 ? [AudioOnsetEvent(sequence: UInt64(tick + 1), time: time, receivedAt: time, strength: 1)] : [], spectralFluxPeak: 0)
            var keys = [KeyboardInputEvent]()
            if tick % 3 == 0 {
                keySequence += 1
                keys.append(KeyboardInputEvent(sequence: keySequence, receivedAt: time, kind: .pressed, keyCode: 0, modifiers: [], heldDuration: nil))
            }
            session.receive(keyboard: KeyboardInput(sessionID: keyboardID, sequence: keySequence, state: .running,
                sampledAt: time, modifiers: [], heldKeys: [], pressesPerSecond: 20, idleDuration: 0, events: keys, droppedEventCount: 0))
            session.update(input: input, deltaTime: 1.0 / 60); baseline.update(input: input, deltaTime: 1.0 / 60)
            let s = session.simulation.scene, b = baseline.simulation.scene
            paired = paired && s.noteY == b.noteY && s.swayAngle == b.swayAngle && s.scale == b.scale && s.trace.count == b.trace.count
            maxAngle = max(maxAngle, abs(s.swayAngle)); minScale = min(minScale, s.scale); maxScale = max(maxScale, s.scale)
        }
        check("Twenty presses/sec run alongside pitch, sway, scale and trail with identical audio motion", paired && session.simulation.keyboardStars.totalBursts == 40 &&
            !session.drawing.stars.isEmpty && maxAngle > 0.15 && maxScale - minScale > 0.2 && session.simulation.scene.pitch?.midi == 69)
        for tick in 120..<780 {
            let time = Double(tick) / 60
            let frame = AudioFeatureFrame(sessionID: audioID, sequence: UInt64(tick + 1), receivedAt: time,
                audio: StaffNotePreview.audio(time, silent: true), melody: nil)
            session.update(input: FeatureInput(sessionID: audioID, state: .running, frame: frame, frameAge: 0, onsets: [], spectralFluxPeak: 0), deltaTime: 1.0 / 60)
        }
        check("Fresh silent audio frames stop redrawing after motion and stars settle", !session.simulation.needsDisplay)
        let silentTime = 13.0
        keySequence += 1
        session.receive(keyboard: KeyboardInput(sessionID: keyboardID, sequence: keySequence, state: .running, sampledAt: silentTime,
            modifiers: [], heldKeys: [], pressesPerSecond: 1, idleDuration: 0,
            events: [KeyboardInputEvent(sequence: keySequence, receivedAt: silentTime, kind: .pressed, keyCode: 49, modifiers: [], heldDuration: nil)], droppedEventCount: 0))
        session.update(input: FeatureInput(sessionID: audioID, state: .running,
            frame: AudioFeatureFrame(sessionID: audioID, sequence: 781, receivedAt: silentTime, audio: StaffNotePreview.audio(silentTime, silent: true), melody: nil),
            frameAge: 0, onsets: [], spectralFluxPeak: 0), deltaTime: 1.0 / 60)
        check("A fresh key wakes rendering while the audio channel stays silent", session.simulation.needsDisplay && session.drawing.stars.count == 7)
        session.deactivate(); session.activate(viewport: viewport)
        check("Native reactivation clears cached star presentation", session.drawing.stars.isEmpty)
        session.dispose(); baseline.dispose()

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/staff-keyboard-platform-tests.json"))
        if failures > 0 { exit(1) }
    }
}
