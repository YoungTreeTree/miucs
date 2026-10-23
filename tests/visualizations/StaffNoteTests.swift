import Foundation

@main
@MainActor
enum StaffNoteTests {
    static func audio(_ time: Double, envelope: Double = 0.1, silent: Bool = false) -> AudioFeatures {
        AudioFeatures(time: time, sampleRate: 48_000, channelCount: 2,
            rms: envelope, rmsDBFS: -20, peak: envelope * 2, crestDB: 6, envelope: envelope,
            isSilent: silent, silenceDuration: silent ? 1 : 0, lowEnergy: 0.001, midEnergy: 0.003,
            highEnergy: 0.001, lowShare: 0.2, midShare: 0.6, highShare: 0.2,
            centroidHz: 2000, bandwidthHz: 1500, flatness: 0.2, spectralFlux: 0.9,
            onsetThreshold: 0.2, isOnset: true, balance: 0, sideEnergyRatio: 0.3,
            correlation: 0.4, displayBands: [])
    }
    static func melody(_ time: Double, _ midi: Double) -> MelodyFrame {
        MelodyFrame(time: time, pitchHz: 440 * pow(2, (midi - 69) / 12), confidence: 1, isMelodic: true)
    }
    static func feed(_ scene: inout StaffNoteScene, _ midi: Double, after seconds: Double = 1024.0 / 48_000) {
        scene.advance(seconds: seconds)
        scene.receive(audio: audio(scene.elapsed))
        scene.receive(melody: melody(scene.elapsed, midi))
    }
    static func input(_ sequence: UInt64, _ midi: Double?, generation: UUID, time: Double? = nil,
                      age: Double = 0, state: AudioSourceState = .running, silent: Bool = false,
                      rate: Double = 48_000, channels: Int = 2, onset: Bool = false) -> FeatureInput {
        let t = time ?? Double(sequence) / 60
        var a = audio(t, silent: silent); a.sampleRate = rate; a.channelCount = channels
        let frame = AudioFeatureFrame(sessionID: generation, sequence: sequence, receivedAt: t,
            audio: a, melody: midi.map { melody(t, $0) })
        return FeatureInput(sessionID: generation, state: state, frame: frame, frameAge: age,
            onsets: onset ? [AudioOnsetEvent(sequence: sequence, time: t, receivedAt: t, strength: 1)] : [], spectralFluxPeak: 1)
    }
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        let natural = [(60, 98.0), (62, 94), (64, 90), (65, 86), (67, 82), (69, 78), (71, 74),
                       (72, 70), (74, 66), (76, 62), (77, 58), (79, 54), (81, 50)]
        check("Natural notes alternate exact staff lines and spaces", natural.allSatisfy { StaffPitch(midi: $0.0)?.y == $0.1 })
        check("Sharps share the natural note position and use sharp spelling", [(60, 61), (62, 63), (65, 66), (67, 68), (69, 70)].allSatisfy {
            StaffPitch(midi: $0.0)?.y == StaffPitch(midi: $0.1)?.y && StaffPitch(midi: $0.1)?.isSharp == true
        } && StaffPitch(midi: 66)?.name == "F♯4")
        check("Octaves preserve seven diatonic steps and 28 points", abs(StaffPitch(midi: 72)!.y - StaffPitch(midi: 60)!.y) == 28)
        check("E2 and C7 fit the fixed 160-point canvas", StaffPitch(midi: 40)!.y == 146 && StaffPitch(midi: 96)!.y == 14)
        check("Ledger lines include all lines between the staff and the head", StaffPitch(midi: 60)!.ledgerYs == [98] &&
            StaffPitch(midi: 62)!.ledgerYs.isEmpty && StaffPitch(midi: 40)!.ledgerYs == [98, 106, 114, 122, 130, 138, 146] &&
            StaffPitch(midi: 96)!.ledgerYs == [50, 42, 34, 26, 18])
        var bad = melody(0, 60); bad.confidence = 0.47
        var nan = melody(0, 60); nan.pitchHz = .nan
        check("Absent, invalid, low confidence and out-of-range pitches are rejected", StaffPitch.resolve(bad, previous: nil) == nil &&
            StaffPitch.resolve(nan, previous: nil) == nil && StaffPitch.resolve(melody(0, 39), previous: nil) == nil &&
            StaffPitch.resolve(melody(0, 97), previous: nil) == nil)
        check("Hysteresis prevents semitone boundary chatter", StaffPitch.resolve(melody(0, 60.6), previous: StaffPitch(midi: 60))?.midi == 60 &&
            StaffPitch.resolve(melody(0, 60.7), previous: StaffPitch(midi: 60))?.midi == 61)
        var idle = StaffNoteScene()
        check("First missing melody waits faintly on B4", idle.pitch == nil && idle.baseY == 74 && idle.opacity == 0.22 && idle.labelOpacity == 0)
        var immediate = true, smooth = true, remaining = 0.0
        for midi in [40.0, 96, 60, 61, 72, 72, 48] {
            idle.receive(audio: audio(idle.elapsed)); let before = idle.baseY
            idle.receive(melody: melody(idle.elapsed, midi))
            immediate = immediate && idle.baseY == before && idle.targetY == StaffPitch(midi: Int(midi))!.y
            let startError = abs(before - idle.targetY)
            var previous = startError
            for tick in 0..<9 {
                idle.advance(seconds: 1.0 / 60)
                let error = abs(idle.baseY - idle.targetY)
                if tick == 0, startError > 0.01 { smooth = smooth && error < startError }
                smooth = smooth && error <= previous + 1e-8; previous = error
            }
            remaining = max(remaining, previous / max(0.01, startError))
            idle.advance(seconds: 0.2)
        }
        check("Fresh targets preserve position and movement starts on the next refresh", immediate && smooth)
        check("Accepted targets and repeated notes settle within 150ms", remaining < 0.05)

        var spikeFree = true, rawExcursions = 0.0, filteredExcursions = 0.0
        for burst in [[57.0], [81], [57, 57], [81, 81], [64], [74]] {
            var scene = StaffNoteScene()
            feed(&scene, 69, after: 0)
            var rawY = StaffPitch(midi: 69)!.y, filteredY = rawY
            for midi in [69.0, 69] + burst + [69, 69, 69, 69] {
                feed(&scene, midi)
                let nextY = StaffPitch(midi: Int(midi))!.y
                rawExcursions += abs(nextY - rawY); rawY = nextY
                filteredExcursions += abs(scene.trace.last!.y - filteredY); filteredY = scene.trace.last!.y
                spikeFree = spikeFree && scene.pitch?.midi == 69 && scene.isPitchReliable
            }
        }
        check("High-confidence isolated notes and two-frame octave intrusions leave no spikes", spikeFree && rawExcursions > 200 && filteredExcursions == 0)

        var steps = StaffNoteScene(), immediateSteps = true
        for midi in [69.0, 70, 72, 71, 69, 67, 69, 71, 72] {
            feed(&steps, midi)
            immediateSteps = immediateSteps && steps.pitch?.midi == Int(midi) && steps.targetY == StaffPitch(midi: Int(midi))!.y
        }
        check("Semitone and whole-tone vocal motion changes the target on its first frame", immediateSteps)

        var delays = [String: Double](), timelyJumps = true, preservesOctaves = true
        for (from, to, limit) in [(60.0, 64.0, 0.03), (69, 64, 0.03), (60, 67, 0.05),
                                  (72, 65, 0.05), (60, 72, 0.075), (72, 60, 0.075)] {
            var scene = StaffNoteScene()
            feed(&scene, from, after: 0)
            let firstCandidateTime = 1024.0 / 48_000
            var delay: Double?
            for _ in 0..<12 {
                feed(&scene, to)
                if delay == nil, scene.pitch?.midi == Int(to) { delay = scene.elapsed - firstCandidateTime }
            }
            delays["\(Int(from))->\(Int(to))"] = (delay ?? 999) * 1000
            timelyJumps = timelyJumps && (delay ?? 999) <= limit
            preservesOctaves = preservesOctaves && scene.targetY == StaffPitch(midi: Int(to))!.y &&
                abs(scene.trace.last!.y - scene.targetY) < 0.1
        }
        check("Sustained thirds, fifths and octaves confirm within 30, 50 and 75ms at 48kHz", timelyJumps)
        check("Confirmed jumps keep their full staff distance and the trail reaches the true note", preservesOctaves)

        var fastPhrase = StaffNoteScene(), followsPhrase = true
        feed(&fastPhrase, 60, after: 0)
        for midi in [64.0, 67, 72, 69, 64, 60] {
            for _ in 0..<5 { feed(&fastPhrase, midi) }
            followsPhrase = followsPhrase && fastPhrase.pitch?.midi == Int(midi)
        }
        check("A quick melodic phrase with thirds and fourths keeps every sustained note", followsPhrase)

        var alternating = StaffNoteScene(), rejectsAlternating = true
        feed(&alternating, 69, after: 0)
        for midi in [81.0, 57, 81, 57, 81, 57, 81, 57, 69] {
            feed(&alternating, midi)
            rejectsAlternating = rejectsAlternating && alternating.pitch?.midi == 69
        }
        check("Unrelated high and low candidates cannot accumulate into a confirmed jump", rejectsAlternating)

        var vibrato = StaffNoteScene()
        feed(&vibrato, 60, after: 0)
        for midi in [72.0, 73, 72, 73] { feed(&vibrato, midi) }
        check("A sustained new register can confirm despite nearby semitone variation", vibrato.pitch?.midi == 73)

        var duplicate = StaffNoteScene()
        feed(&duplicate, 69, after: 0); feed(&duplicate, 81)
        let repeatedTime = duplicate.elapsed, beforeDuplicateCount = duplicate.trace.count
        for _ in 0..<12 {
            duplicate.advance(seconds: 1.0 / 240)
            duplicate.receive(audio: audio(duplicate.elapsed))
            duplicate.receive(melody: melody(repeatedTime, 81))
        }
        let ignoredDuplicates = duplicate.pitch?.midi == 69 && duplicate.trace.count == beforeDuplicateCount
        feed(&duplicate, 81)
        check("Repeated snapshots cannot confirm a jump or append trajectory points", ignoredDuplicates && duplicate.pitch?.midi == 69)

        var sparse = StaffNoteScene()
        feed(&sparse, 69, after: 0)
        feed(&sparse, 81); feed(&sparse, 81, after: 0.08); feed(&sparse, 81, after: 0.08)
        check("Widely spaced observations cannot be treated as continuous confirmation", sparse.pitch?.midi == 69)

        var held = StaffNoteScene()
        feed(&held, 69, after: 0)
        for i in 0..<10 { feed(&held, i.isMultiple(of: 2) ? 57 : 81) }
        held.advance(seconds: 0.03)
        check("Unconfirmed candidates do not keep an old reliable pitch alive indefinitely", !held.isPitchReliable && held.pitch?.midi == 69)
        held.receive(audio: audio(held.elapsed)); held.receive(melody: melody(held.elapsed, 57))
        check("The first fresh pitch after expiry starts a new segment immediately", held.pitch?.midi == 57 && held.trace.last?.y == StaffPitch(midi: 57)!.y)

        var interrupted = StaffNoteScene()
        feed(&interrupted, 69, after: 0); feed(&interrupted, 81); feed(&interrupted, 81)
        interrupted.receive(melody: nil); feed(&interrupted, 57)
        check("Missing melody clears pending confirmation and starts the next trace at its true height", interrupted.pitch?.midi == 57 &&
            interrupted.trace.first?.segment != interrupted.trace.last?.segment && interrupted.trace.last?.y == StaffPitch(midi: 57)!.y)

        var softened = StaffNoteScene()
        feed(&softened, 69, after: 0); feed(&softened, 71)
        let firstTrailY = softened.trace.last!.y
        for _ in 0..<3 { feed(&softened, 71) }
        check("The trail softens its first corner and reaches 95 percent of a small change within 90ms",
            softened.pitch?.midi == 71 && firstTrailY > 74 && firstTrailY < 78 && abs(softened.trace.last!.y - 74) < 0.2 &&
            softened.trace.allSatisfy { (74...78).contains($0.y) })

        var quiet = StaffNoteScene(), loud = StaffNoteScene()
        var bounded = true, continuous = true, traceIsPitch = true
        for i in 0..<720 {
            let t = Double(i) / 120
            quiet.receive(audio: audio(t, envelope: 0.005)); loud.receive(audio: audio(t, envelope: 0.3))
            quiet.receive(melody: melody(t, 66)); loud.receive(melody: melody(t, 66))
            let before = loud.noteY
            if i.isMultiple(of: 3) {
                quiet.receiveOnset(strength: 1); loud.receiveOnset(strength: 1)
                continuous = continuous && loud.noteY == before
            }
            quiet.advance(seconds: 1.0 / 120); loud.advance(seconds: 1.0 / 120)
            bounded = bounded && (-4...0).contains(loud.bounce) && loud.scale <= 1.11
            traceIsPitch = traceIsPitch && loud.trace.last?.pitch.y == 86 && loud.trace.last?.y == quiet.trace.last?.y
        }
        check("Volume changes size while leaving true pitch and base motion identical", loud.scale > quiet.scale + 0.08 && loud.baseY == quiet.baseY && loud.targetY == 86)
        check("Dense onsets preserve continuous position and bounded bounce", bounded && continuous && loud.bounce < 0)
        check("Trace preserves the accepted note and ignores loudness and decorative bounce", traceIsPitch)
        check("Trace capacity never exceeds 512 samples", loud.trace.count == 512)
        let point = loud.trace.last!, x = loud.traceX(loud.trace.last!)
        loud.receive(audio: nil); loud.advance(seconds: 1)
        check("History moves left in real time and fades", abs(loud.traceX(point) - (x - 70)) < 1e-8 && loud.traceOpacity(point) < 1)
        loud.advance(seconds: 8)
        check("All history expires after eight seconds, including long scheduling gaps", loud.trace.isEmpty)
        check("Unreliable pitch holds the last height and fades the label", loud.pitch?.name == "F♯4" && loud.targetY == 86 && !loud.isPitchReliable && loud.labelOpacity < 0.02)
        let count = quiet.trace.count
        quiet.receive(melody: nil); quiet.receiveOnset(strength: 1); quiet.advance(seconds: 0.1)
        check("Sound without melody holds pitch, stops history and still follows onsets", quiet.trace.count == count && quiet.targetY == 86 && quiet.canBounce && quiet.bounce < 0)
        quiet.receive(audio: audio(8, silent: true)); quiet.receive(melody: melody(8, 60)); quiet.receiveOnset(strength: 1)
        quiet.advance(seconds: 0.25)
        check("Silence stops kicks while existing bounce settles smoothly", !quiet.canBounce && abs(quiet.bounce) < 0.04)

        let simulation = StaffNoteSimulation(), generation = UUID()
        simulation.activate(viewport: VisualizationViewport(width: 800, height: 160, scale: 1))
        let first = input(1, 60, generation: generation, onset: true)
        simulation.update(input: first, deltaTime: 1.0 / 60)
        let firstCount = simulation.scene.trace.count
        simulation.update(input: first, deltaTime: 1.0 / 60)
        check("Snapshot and event duplicates do not replay actions or trajectory", firstCount == 1 && simulation.scene.trace.count == 1)
        for _ in 0..<20 { simulation.update(input: first, deltaTime: 1.0 / 60) }
        check("Cached melody expires even when the snapshot remains fresh", !simulation.scene.isPitchReliable)
        simulation.update(input: input(2, 72, generation: generation, age: 0.5, onset: true), deltaTime: 1.0 / 60)
        check("Stale audio cannot move the note or start actions", simulation.scene.targetY == 98 && !simulation.scene.canBounce)
        simulation.update(input: input(1, 67, generation: UUID(), onset: false), deltaTime: 1.0 / 60)
        check("Reconnect isolates old history and accepts the new generation", simulation.scene.trace.count == 1 && simulation.scene.targetY == 82)
        simulation.update(input: input(3, 60, generation: generation, onset: true), deltaTime: 1.0 / 60)
        let oldBounce = simulation.scene.bounce
        simulation.update(input: input(4, 72, generation: generation, rate: 44_100, channels: 1, onset: true), deltaTime: 1.0 / 60)
        check("Audio format changes discard old history and queued kicks", simulation.scene.trace.count == 1 && simulation.scene.targetY == 70 && simulation.scene.bounce > oldBounce)
        simulation.update(input: input(5, 64, generation: generation, time: 0, rate: 44_100, channels: 1), deltaTime: 1.0 / 60)
        check("PCM timeline reset does not connect unrelated trajectories", simulation.scene.trace.count == 1 && simulation.scene.targetY == 90)
        simulation.deactivate()
        simulation.update(input: input(6, 96, generation: generation), deltaTime: 1)
        check("Hidden session stops consuming and clears hidden history", simulation.scene.trace.isEmpty && simulation.scene.targetY == 90)
        simulation.activate(viewport: .desktop)
        simulation.update(input: input(8, 72, generation: generation, age: 1, onset: true), deltaTime: 1.0 / 60)
        check("Resume rejects an expired hidden snapshot", simulation.scene.trace.isEmpty && !simulation.scene.canBounce)
        simulation.update(input: input(9, 72, generation: generation), deltaTime: 1.0 / 60)
        check("Resume starts a fresh trajectory from current reliable input", simulation.scene.trace.count == 1 && simulation.scene.targetY == 70)
        simulation.update(input: input(10, 96, generation: generation, state: .recovering, onset: true), deltaTime: 0.2)
        check("Disconnected state holds height and lets existing history fade", simulation.scene.targetY == 70 && simulation.scene.trace.count == 1 && !simulation.scene.canBounce)
        var segmented = StaffNoteScene()
        segmented.receive(audio: audio(0)); segmented.receive(melody: melody(0, 60)); segmented.receive(melody: nil)
        segmented.receive(melody: melody(0.1, 72))
        check("Missing melody breaks the drawn trajectory between reliable segments", segmented.trace.count == 2 && segmented.trace[0].segment != segmented.trace[1].segment)

        let channel = FeatureChannel(), channelID = UUID(), registry = VisualizationRegistry()
        channel.reset(sessionID: channelID, state: .running)
        registry.register(PencilFlightSimulation.module) { PencilFlightSimulation() }
        registry.register(StaffNoteSimulation.module) { StaffNoteSimulation() }
        let controller = VisualizationController(source: channel, registry: registry)
        _ = controller.select(id: "pencil-flight"); controller.resume()
        channel.publish(audio: audio(0), melody: melody(0, 60), sessionID: channelID)
        _ = controller.select(id: "staff-note"); controller.tick(deltaTime: 1.0 / 60)
        let mounted = controller.current as! StaffNoteSimulation
        check("Switch through the real channel consumes current pitch without old bursts", mounted.scene.trace.count == 1 && mounted.scene.bounce == 0 && mounted.scene.targetY == 98)
        channel.publish(audio: audio(0.02), melody: melody(0.02, 72), sessionID: channelID)
        controller.tick(deltaTime: 1.0 / 60)
        check("New channel onsets animate immediately while a large pitch jump is pending", mounted.scene.bounce < 0 && mounted.scene.targetY == 98)
        for (time, midi) in [(0.04, 72.0), (0.06, 72), (0.08, 72)] {
            channel.publish(audio: audio(time), melody: melody(time, midi), sessionID: channelID)
            controller.tick(deltaTime: 0.02)
        }
        check("A sustained octave is confirmed through the production feature channel", mounted.scene.targetY == 70)
        controller.pause()
        channel.publish(audio: audio(0.1), melody: melody(0.1, 96), sessionID: channelID)
        let pausedBounce = mounted.scene.bounce
        controller.resume(); controller.tick(deltaTime: 1.0 / 60)
        check("Hidden channel events are skipped and only current pitch starts fresh history", mounted.scene.trace.count == 1 && mounted.scene.trace[0].pitch.midi == 96 && mounted.scene.bounce > pausedBounce)
        channel.publish(audio: audio(9), melody: melody(9, 60), sessionID: channelID)
        controller.tick(deltaTime: 9)
        check("Long render stalls expire old history while retaining the fresh current sample", mounted.scene.trace.count == 1 && mounted.scene.trace[0].pitch.midi == 60 && mounted.scene.traceX(mounted.scene.trace[0]) > 639)
        controller.dispose()

        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures,
            "maximumRemainingFractionAt150ms": remaining, "pitchConfirmationMillisecondsAt48kHz": delays,
            "syntheticIntrusions": ["rawVerticalTravel": rawExcursions, "filteredVerticalTravel": filteredExcursions],
            "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "docs/validation/staff-note-tests.json"))
        if failures > 0 { exit(1) }
    }
}
