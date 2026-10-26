import AppKit

@main
@MainActor
enum StaffBeatTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func event(_ sequence: UInt64, at time: Double, confidence: Double = 0.9) -> AudioBeatEvent {
            AudioBeatEvent(sequence: sequence, time: time, receivedAt: time, strength: 1, bpm: 120, confidence: confidence)
        }
        var rings = StaffBeatRings()
        rings.advance(seconds: 0, events: [event(1, at: 0)], now: 0, through: 1)
        let birth = rings.rings.first!
        rings.advance(seconds: 0.1, events: [event(1, at: 0)], now: 0.1, through: 1)
        check("A beat softly reveals two main arcs and starts a small ripple without replaying repeated snapshots", rings.totalPulses == 1 &&
            rings.rings.count == 3 && rings.rings[0].radius > birth.radius && rings.rings[0].opacity > birth.opacity &&
            rings.rings[1].radius < rings.rings[0].radius)
        let earlySatellite = rings.rings[2]
        check("The main ripple keeps its random center while its smaller companion moves outwards",
              rings.rings[0].x == birth.x && rings.rings[0].y == birth.y &&
              hypot(earlySatellite.x - birth.x, earlySatellite.y - birth.y) > 0)
        rings.advance(seconds: 0.2, events: [], now: 0.3, through: 1)
        check("The smaller main wave remains clearly visible with a maximum 64-point diameter",
              rings.rings[0].radius > 22 && rings.rings[0].radius <= 32 && rings.rings[0].opacity > 0.4)
        check("Two main arcs carry three distinct smaller arcs with a compact outward spread",
              rings.rings.count == 5 && rings.rings.dropFirst(2).allSatisfy {
                  $0.arc == .satellite && $0.radius < 8.3 && hypot($0.x - birth.x, $0.y - birth.y) <= 42 && $0.opacity > 0
              } && hypot(rings.rings[2].x - birth.x, rings.rings[2].y - birth.y) >
                  hypot(earlySatellite.x - birth.x, earlySatellite.y - birth.y))
        rings.advance(seconds: 0.52, events: [], now: 0.82, through: 1)
        check("The delayed inner arc softly finishes after the outer arc", rings.rings.count == 1 && rings.rings[0].opacity < 0.1)
        let expired = rings.advance(seconds: 0.08, events: [], now: 0.9, through: 1)
        check("Expiration requests a final redraw and a settled ring layer stops invalidation", expired && rings.rings.isEmpty &&
            !rings.advance(seconds: 1, events: [], now: 1.5, through: 1))
        rings.advance(seconds: 1, events: [event(2, at: 1), event(3, at: 2, confidence: 0.2)], now: 2, through: 3)
        check("Stale or low-confidence beat events never create rings", rings.rings.isEmpty)
        rings.advance(seconds: 3, events: [event(4, at: 5)], now: 5, through: 4)
        check("A fresh pulse after a long frame is shown at its actual age", rings.rings.count == 1 && rings.rings[0].opacity == birth.opacity)
        rings.advance(seconds: 0, events: (5...20).map { event(UInt64($0), at: 5) }, now: 5, through: 20)
        check("A pathological backlog retains only four recent beat pulses", rings.rings.count == StaffBeatRings.pulseLimit)
        rings.advance(seconds: 0.25, events: [], now: 5.25, through: 20)
        check("Four simultaneous main-and-small bursts fit twenty reusable arc slots", rings.rings.count == StaffBeatRings.limit)
        rings.advance(seconds: 4, events: [], now: 9, through: 20)
        check("A long frame expires all old rings without replaying them", rings.rings.isEmpty)

        var scattered = StaffBeatRings(seed: 0x42454154), origins = [StaffBeatRing]()
        for i in 1...48 {
            let time = Double(i) * 0.5
            scattered.advance(seconds: 0.5, events: [event(UInt64(i), at: time)], now: time, through: UInt64(i))
            origins.append(scattered.rings.last!)
        }
        let acrossCanvas = origins.map(\.x).max()! - origins.map(\.x).min()! > 480 &&
            origins.map(\.y).max()! - origins.map(\.y).min()! > 45
        let separated = zip(origins, origins.dropFirst()).allSatisfy { abs($0.0.x - $0.1.x) >= 120 }
        check("New beats scatter across the staff with safe margins and separated successive centers",
              acrossCanvas && separated && origins.allSatisfy {
                  StaffBeatRings.horizontalRange.contains($0.x) && StaffBeatRings.verticalRange.contains($0.y)
              })

        let session = MacStaffNoteSession(), baseline = MacStaffNoteSession(), generation = UUID(), keyboardID = UUID()
        let viewport = VisualizationViewport(width: 800, height: 160, scale: 1)
        session.activate(viewport: viewport); baseline.activate(viewport: viewport)
        func input(_ sequence: UInt64, generation id: UUID = generation, midi: Double? = 67,
                   age: Double = 0, silent: Bool = false, rate: Double = 48_000, beat: Bool = true) -> FeatureInput {
            let t = Double(sequence) / 60
            var audio = StaffNotePreview.audio(t, silent: silent); audio.sampleRate = rate
            audio.envelope = sequence % 40 < 20 ? 0.015 : 0.22
            let frame = AudioFeatureFrame(sessionID: id, sequence: sequence, receivedAt: t, audio: audio,
                                         melody: midi.map { StaffNotePreview.melody(t, midi: $0) })
            return FeatureInput(sessionID: id, state: .running, frame: frame, frameAge: age,
                onsets: sequence % 20 == 0 ? [AudioOnsetEvent(sequence: sequence, time: t, receivedAt: t, strength: 1)] : [],
                spectralFluxPeak: 0.9, beats: beat ? [event(sequence, at: t)] : [])
        }
        session.update(input: input(1, midi: nil), deltaTime: 1.0 / 60)
        check("A percussion-only frame with no vocal pitch still displays a ring", session.simulation.scene.pitch == nil && session.drawing.rings.count == 1)
        baseline.update(input: input(1, midi: nil, beat: false), deltaTime: 1.0 / 60)
        session.deactivate(); session.activate(viewport: viewport)
        baseline.deactivate(); baseline.activate(viewport: viewport)
        var identical = true, simultaneous = false, maxAngle = 0.0, minScale = 10.0, maxScale = 0.0
        for tick in 1...180 {
            let t = Double(tick) / 60, seq = UInt64(tick)
            let keys = tick % 3 == 0 ? [KeyboardInputEvent(sequence: seq, receivedAt: t, kind: .pressed,
                keyCode: 0, modifiers: [], heldDuration: nil, modifierIsPressed: nil)] : []
            session.receive(keyboard: KeyboardInput(sessionID: keyboardID, sequence: seq, state: .running, sampledAt: t,
                modifiers: [], heldKeys: [], pressesPerSecond: 20, idleDuration: 0, events: keys, droppedEventCount: 0))
            let a = input(seq, midi: tick < 90 ? 67 : 69, beat: tick % 30 == 0)
            var b = a; b.beats = []
            session.update(input: a, deltaTime: 1.0 / 60); baseline.update(input: b, deltaTime: 1.0 / 60)
            let scene = session.simulation.scene, control = baseline.simulation.scene
            identical = identical && scene.noteY == control.noteY && scene.scale == control.scale && scene.swayAngle == control.swayAngle && scene.trace == control.trace
            simultaneous = simultaneous || (!session.drawing.rings.isEmpty && !session.drawing.stars.isEmpty && abs(scene.swayAngle) > 0.05)
            maxAngle = max(maxAngle, abs(scene.swayAngle)); minScale = min(minScale, scene.scale); maxScale = max(maxScale, scene.scale)
        }
        check("Beat rings, stars, pitch movement, sway and volume scaling run together without changing musical positions",
              identical && simultaneous && maxAngle > 0.1 && maxScale - minScale > 0.2)
        session.update(input: input(181, silent: true), deltaTime: 0.01)
        check("Silence clears rings while existing keyboard stars keep fading", session.drawing.rings.isEmpty && !session.drawing.stars.isEmpty)
        session.update(input: input(182), deltaTime: 0.01)
        session.update(input: input(183, age: 0.5), deltaTime: 0.01)
        check("Stale transport snapshots clear rings and cannot replay their beat", session.drawing.rings.isEmpty)
        session.update(input: input(184), deltaTime: 0.01)
        session.update(input: input(185, rate: 44_100), deltaTime: 0.01)
        check("Format changes discard prior rings and queued events", session.drawing.rings.isEmpty)
        session.update(input: input(186, rate: 44_100), deltaTime: 0.01)
        session.update(input: input(1, generation: UUID(), beat: false), deltaTime: 0.01)
        check("A new audio generation clears the previous pulse clock", session.drawing.rings.isEmpty)
        session.update(input: input(190), deltaTime: 0.01)
        session.deactivate(); session.activate(viewport: viewport)
        check("Hiding or switching a module removes cached rings before the first redraw", session.drawing.rings.isEmpty)
        let stopped = FeatureInput(sessionID: UUID(), state: .stopped, frame: nil, frameAge: nil, onsets: [], spectralFluxPeak: 0)
        for _ in 0..<180 { session.update(input: stopped, deltaTime: 1.0 / 60) }
        check("Settled silent input stops requesting animation updates", !session.simulation.needsDisplay)

        let scene = StaffNotePreview.sampleScene(midi: 60), ring = StaffBeatRing(x: 280, y: 88, radius: 26, opacity: 1)
        let previewRings = [ring, StaffBeatRing(x: 250, y: 64, radius: 9, opacity: 0.8, lineWidth: 0.65, arc: .satellite),
                            StaffBeatRing(x: 315, y: 69, radius: 10, opacity: 0.8, lineWidth: 0.65, arc: .satellite),
                            StaffBeatRing(x: 286, y: 128, radius: 8, opacity: 0.8, lineWidth: 0.65, arc: .satellite)]
        let view = StaffNoteView(preview: scene); view.wantsLayer = true
        view.updatePreview(scene, rings: [ring]); view.updateLayer()
        let root = view.layer!.sublayers!.first!, layers = root.sublayers!
        let container = layers.first { $0.name == "beat-rings" }!, pool = container.sublayers!
        let index = layers.firstIndex(of: container)!, ids = pool.map(ObjectIdentifier.init)
        let path = (pool[0].sublayers![4] as! CAShapeLayer).path!
        check("Twenty cached tapered arcs sit above stars and below note, marker and names", pool.count == 20 && pool.allSatisfy { $0.sublayers?.count == 6 } &&
              layers.firstIndex { $0.name == "keyboard-stars" }! < index && layers.firstIndex { $0.name == "pitch-marker" }! > index &&
              layers.firstIndex { $0.name == "pitch-label" }! > index && path.boundingBox.width > 10)
        var moves = 0, closures = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
            if element.pointee.type == .closeSubpath { closures += 1 }
        }
        check("Main wave consists of three open arcs with softened tips", moves == 3 && closures == 0 &&
              (pool[0].sublayers![1] as! CAShapeLayer).opacity < (pool[0].sublayers![5] as! CAShapeLayer).opacity)
        var uniform = true, fullRadius = true, constantStroke = true
        for width in [600.0, 800, 1600] {
            view.setFrameSize(NSSize(width: width, height: width / 5))
            for midi in [43.0, 60, 84] {
                let edge = StaffNotePreview.sampleScene(midi: midi)
                view.updatePreview(edge, rings: [StaffBeatRing(x: ring.x, y: ring.y, radius: 32, opacity: 1)]); view.updateLayer()
                let global = root.affineTransform(), local = pool[0].affineTransform()
                uniform = uniform && global.a == global.d && abs(local.d / local.a - 0.9) < 0.001 && pool[0].position.x == ring.x && pool[0].position.y == ring.y
                fullRadius = fullRadius && abs(10 * local.a - 32) < 0.001
                let stroke = pool[0].sublayers![1] as! CAShapeLayer, halo = pool[0].sublayers![0] as! CAShapeLayer
                constantStroke = constantStroke && abs(stroke.lineWidth * local.a - 1.05) < 0.001 && abs((halo.lineWidth - stroke.lineWidth) * local.a - 0.85) < 0.001
            }
        }
        check("Rings stay at their own centers through pitch changes and scale uniformly at 600/800/1600 points", uniform && fullRadius)
        check("Expanding an arc preserves thin logical strokes and halo widths", constantStroke)
        check("Animation retains the same twenty layer objects and cached arc path", pool.map(ObjectIdentifier.init) == ids &&
              (pool[0].sublayers![4] as! CAShapeLayer).path === path)
        view.updatePreview(scene); view.updateLayer()
        check("Expired ring layers are hidden and remain reusable", pool.allSatisfy(\.isHidden))
        let directory = URL(fileURLWithPath: "build/staff-beat-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var colors = true, visible = true, headClear = true
        for ink in VisualizationInk.allCases {
            let b = StaffNotePreview.bitmap(scene: scene, width: 800, retainedLayers: true, rings: previewRings, appearance: ink.appearance)
            var matching = 0
            // Lower semicircle is free of the stem, staff and melody trail.
            for y in 200..<250 { for x in 490..<630 {
                let c = b.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if c.alphaComponent > 0.8 && abs(c.redComponent - ink.color.red) < 0.1 && abs(c.greenComponent - ink.color.green) < 0.1 && abs(c.blueComponent - ink.color.blue) < 0.1 { matching += 1 }
            } }
            colors = colors && matching > 10
            try b.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("ring-\(ink.id).png"))
        }
        for width in [600, 800, 1600] { for (name, color) in [("light", NSColor.white), ("dark", NSColor(calibratedWhite: 0.12, alpha: 1))] {
            let base = StaffNotePreview.bitmap(scene: scene, width: width, background: color, retainedLayers: true)
            let b = StaffNotePreview.bitmap(scene: scene, width: width, background: color, retainedLayers: true, rings: previewRings)
            let scale = Double(width) / 400
            var changed = 0
            for y in Int(100 * scale)..<Int(125 * scale) { for x in Int(245 * scale)..<Int(315 * scale) {
                if !b.colorAt(x: x, y: y)!.isEqual(base.colorAt(x: x, y: y)!) { changed += 1 }
            } }
            visible = visible && changed > 20
            headClear = headClear && b.colorAt(x: Int(640 * scale), y: Int(98 * scale))!.isEqual(base.colorAt(x: Int(640 * scale), y: Int(98 * scale))!)
            try b.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("ring-\(width)-\(name).png"))
        } }
        check("All five global pen colors reach the tapered native arcs", colors)
        check("Rings are visible on both backgrounds at all sizes and preserve the solid head", visible && headClear)
        var softEdges = true
        for retained in [false, true] { for width in [600, 800, 1600] { for midi in [43.0, 84] {
            let edge = StaffNotePreview.sampleScene(midi: midi), scale = Double(width) / 400
            let edgeRing = StaffBeatRing(x: 280, y: midi == 43 ? 140 : 20, radius: 32, opacity: 1, rotation: midi == 43 ? 0 : .pi)
            let b = StaffNotePreview.bitmap(scene: edge, width: width, retainedLayers: retained, rings: [edgeRing])
            func rowAlpha(_ y: Double) -> Double {
                (Int(245 * scale)..<Int(315 * scale)).map {
                    Double(b.colorAt(x: $0, y: Int(y * scale))!.alphaComponent)
                }.max()!
            }
            let outside = rowAlpha(midi == 43 ? 159.5 : 0.5), inside = rowAlpha(midi == 43 ? 151.5 : 8.5)
            softEdges = softEdges && outside < 0.22 && inside > 0.4
            if retained && width == 800 {
                try b.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("ring-edge-\(Int(midi)).png"))
            }
        } } }
        check("Native layers and export drawing softly fade rings at canvas edges at all sizes", softEdges)
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/staff-beat-tests.json"))
        if failures > 0 { exit(1) }
    }
}
