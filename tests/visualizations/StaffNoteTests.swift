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
    static func singing(_ time: Double, _ midi: Double?) -> MelodyFrame {
        MelodyFrame(time: time, pitchHz: midi.map { 440 * pow(2, ($0 - 69) / 12) },
                    confidence: midi == nil ? 0 : 0.35, isMelodic: midi != nil, estimator: .crepe)
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
        var bad = melody(0, 60); bad.confidence = 0.47
        var nan = melody(0, 60); nan.pitchHz = .nan
        check("Absent, invalid, low confidence and out-of-range pitches are rejected", StaffPitch.resolve(bad, previous: nil) == nil &&
            StaffPitch.resolve(nan, previous: nil) == nil && StaffPitch.resolve(melody(0, 39), previous: nil) == nil &&
            StaffPitch.resolve(melody(0, 97), previous: nil) == nil)
        check("Staff following accepts G2 through C6 and rejects neighboring notes without clamping",
            StaffPitch.resolve(melody(0, 43), previous: nil)?.midi == 43 &&
            StaffPitch.resolve(melody(0, 84), previous: nil)?.midi == 84 &&
            [40.0, 42, 85, 96].allSatisfy { StaffPitch.resolve(melody(0, $0), previous: nil) == nil })
        check("Hysteresis prevents semitone boundary chatter", StaffPitch.resolve(melody(0, 60.6), previous: StaffPitch(midi: 60))?.midi == 60 &&
            StaffPitch.resolve(melody(0, 60.7), previous: StaffPitch(midi: 60))?.midi == 61)
        check("Gated CREPE confidence uses its own scale rather than the spectral cutoff", [0.30, 0.40, 0.47].allSatisfy {
            var frame = singing(0, 60); frame.confidence = $0
            return StaffPitch.resolve(frame, previous: nil)?.midi == 60
        })
        var unvoiced = singing(0, 60); unvoiced.isMelodic = false
        var invalidConfidence = singing(0, 60); invalidConfidence.confidence = .nan
        check("Trusting the CREPE gate still rejects unvoiced, nonfinite and out-of-range observations",
            StaffPitch.resolve(unvoiced, previous: nil) == nil &&
            StaffPitch.resolve(invalidConfidence, previous: nil) == nil &&
            StaffPitch.resolve(singing(0, nil), previous: nil) == nil &&
            StaffPitch.resolve(singing(0, 96), previous: nil) == nil)
        var idle = StaffNoteScene()
        check("First missing melody waits faintly on B4", idle.pitch == nil && idle.baseY == 74 && idle.opacity == 0.22 && idle.labelOpacity == 0)
        var immediate = true, smooth = true, remaining = 0.0
        for midi in [43.0, 84, 60, 61, 72, 72, 48] {
            idle.resetInput(clearHistory: false)
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
        for burst in [[57.0], [81], [57, 57], [81, 81], [64], [74],
                      [64, 64, 64, 64, 64], [76, 76, 76, 76, 76], [81, 81, 81, 81, 81]] {
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
        check("High-confidence intrusions lasting up to five frames leave no pitch spikes", spikeFree && rawExcursions > 200 && filteredExcursions == 0)

        var rejected = StaffNoteScene()
        feed(&rejected, 69, after: 0)
        let acceptedTrace = rejected.trace
        for midi in [96.0, 40, 85, 42, 96] { feed(&rejected, midi) }
        check("Brief out-of-range bursts hold the last pitch and add no trace or edge notes",
            rejected.pitch?.midi == 69 && rejected.targetY == 78 && rejected.isPitchReliable && rejected.trace == acceptedTrace)
        feed(&rejected, 69)
        check("Returning from a brief rejected range keeps a continuous trace without adding rejected samples",
            rejected.trace.count == 2 && rejected.trace.last?.segment == acceptedTrace.last?.segment && rejected.trace.last?.y == 78)
        for _ in 0..<20 { feed(&rejected, 96) }
        check("Persistent out-of-range sound expires the label without moving or extending the trail",
            !rejected.isPitchReliable && rejected.pitch?.midi == 69 && rejected.targetY == 78 && rejected.trace.count == 2)
        var outsideOnly = StaffNoteScene()
        for midi in [40.0, 42, 85, 96] { feed(&outsideOnly, midi) }
        check("Out-of-range sound at startup does not invent a boundary note", outsideOnly.pitch == nil && outsideOnly.trace.isEmpty)

        var pendingTrace = StaffNoteScene()
        feed(&pendingTrace, 60, after: 0)
        let beforePending = pendingTrace.trace
        for _ in 0..<5 { feed(&pendingTrace, 72) }
        check("Unconfirmed jumps pause the trail instead of appending held or guessed pitches",
            pendingTrace.pitch?.midi == 60 && pendingTrace.trace == beforePending && pendingTrace.hasContinuousTraceTail)
        for _ in 0..<4 { feed(&pendingTrace, 72) }
        check("Confirmed jumps join the previous reliable point across a short confirmation interval",
            pendingTrace.pitch?.midi == 72 && pendingTrace.trace.count == 2 &&
            pendingTrace.trace.last?.segment == beforePending.last?.segment && abs(pendingTrace.trace.last!.y - 70) < 0.02)

        var longGap = StaffNoteScene()
        feed(&longGap, 69, after: 0)
        let oldSegment = longGap.trace.last!.segment
        for _ in 0..<60 {
            longGap.advance(seconds: 0.02); longGap.receive(audio: audio(longGap.elapsed)); longGap.receive(melody: nil)
        }
        check("Missing pitch expires its live tail even while accompaniment continues",
            !longGap.hasContinuousTraceTail && longGap.trace.count == 1 && !longGap.isPitchReliable)
        feed(&longGap, 69)
        check("Pitch after a model-only gap reconnects the same audible session", longGap.trace.last?.segment == oldSegment)
        let beforeSilence = longGap.trace.last!.segment
        longGap.receive(audio: audio(longGap.elapsed, silent: true)); feed(&longGap, 71)
        check("Real silence still breaks the trace immediately", longGap.trace.last?.segment != beforeSilence)

        var softJoin = StaffNoteScene()
        softJoin.receive(audio: audio(0)); softJoin.receive(melody: singing(0, 71))
        for tick in 1...30 {
            let time = Double(tick) * 0.02
            softJoin.advance(seconds: 0.02); softJoin.receive(audio: audio(time))
            softJoin.receive(melody: singing(time, nil))
        }
        softJoin.advance(seconds: 0.02); softJoin.receive(audio: audio(0.62))
        softJoin.receive(melody: singing(0.62, 72), age: 0.12)
        let join = softJoin.trace.last!.join!, joinedHistory = softJoin.trace
        check("A returning delayed pitch starts a fresh visual join while the new note is immediately accepted",
              softJoin.pitch?.midi == 72 && join.progress(at: softJoin.elapsed) == 0 &&
              abs(join.startedAt - softJoin.elapsed) < 1e-9)
        softJoin.advance(seconds: 0.1); softJoin.receive(audio: audio(softJoin.elapsed))
        let halfway = join.progress(at: softJoin.elapsed)
        softJoin.receive(melody: singing(0.62, 72), age: 0.12)
        check("Join growth advances between analysis frames and duplicate snapshots cannot restart it",
              halfway > 0 && halfway < 1 && softJoin.trace == joinedHistory &&
              softJoin.trace.last?.join?.progress(at: softJoin.elapsed) == halfway)
        softJoin.advance(seconds: 1)
        check("A long frame settles a pending visual join without adding or moving any pitch samples",
              join.progress(at: softJoin.elapsed) == 1 && softJoin.trace == joinedHistory)

        var filteredPhrase = StaffNoteScene(), staysConnected = true
        feed(&filteredPhrase, 69, after: 0)
        for gap in [6, 18, 40, 60] {
            let count = filteredPhrase.trace.count, segment = filteredPhrase.trace.last!.segment
            for tick in 0..<gap {
                filteredPhrase.advance(seconds: 0.02)
                filteredPhrase.receive(audio: audio(filteredPhrase.elapsed))
                var candidate = melody(filteredPhrase.elapsed, tick.isMultiple(of: 2) ? 96 : 71)
                if !tick.isMultiple(of: 2) { candidate.confidence = 0.1 }
                filteredPhrase.receive(melody: tick.isMultiple(of: 3) ? nil : candidate)
            }
            staysConnected = staysConnected && filteredPhrase.trace.count == count && (gap < 12 ? filteredPhrase.hasContinuousTraceTail : !filteredPhrase.hasContinuousTraceTail)
            feed(&filteredPhrase, 69)
            staysConnected = staysConnected && filteredPhrase.trace.last?.segment == segment
        }
        check("Filtering gaps keep one session contour while stale pitch never draws a held-note tail", staysConnected)
        for _ in 0..<410 {
            filteredPhrase.advance(seconds: 0.02)
            filteredPhrase.receive(audio: audio(filteredPhrase.elapsed)); filteredPhrase.receive(melody: nil)
        }
        check("A continuous visual tail expires with its eight-second history instead of persisting indefinitely",
            filteredPhrase.trace.isEmpty && !filteredPhrase.hasContinuousTraceTail)

        var steps = StaffNoteScene(), immediateSteps = true
        for midi in [69.0, 70, 72, 71, 69, 67, 69, 71, 72] {
            feed(&steps, midi)
            immediateSteps = immediateSteps && steps.pitch?.midi == Int(midi) && steps.targetY == StaffPitch(midi: Int(midi))!.y
        }
        check("Semitone and whole-tone vocal motion changes the target on its first frame", immediateSteps)

        var delays = [String: Double](), timelyJumps = true, preservesOctaves = true
        for (from, to, minimum, limit) in [(60.0, 64.0, 0.10, 0.12), (69, 64, 0.10, 0.12), (60, 67, 0.125, 0.14),
                                           (72, 65, 0.125, 0.14), (60, 72, 0.15, 0.18), (72, 60, 0.15, 0.18)] {
            var scene = StaffNoteScene()
            feed(&scene, from, after: 0)
            let firstCandidateTime = 1024.0 / 48_000
            var delay: Double?
            for _ in 0..<16 {
                feed(&scene, to)
                if delay == nil, scene.pitch?.midi == Int(to) { delay = scene.elapsed - firstCandidateTime }
            }
            delays["\(Int(from))->\(Int(to))"] = (delay ?? 999) * 1000
            timelyJumps = timelyJumps && (delay ?? 999) >= minimum && (delay ?? 999) <= limit
            preservesOctaves = preservesOctaves && scene.targetY == StaffPitch(midi: Int(to))!.y &&
                abs(scene.trace.last!.y - scene.targetY) < 0.1
        }
        check("Sustained thirds, fifths and octaves require 100, 125 and 150ms and confirm within one hop", timelyJumps)
        check("Confirmed jumps keep their full staff distance and the trail reaches the true note", preservesOctaves)

        var fastPhrase = StaffNoteScene(), followsPhrase = true
        feed(&fastPhrase, 60, after: 0)
        for midi in [64.0, 67, 72, 69, 64, 60] {
            for _ in 0..<10 { feed(&fastPhrase, midi) }
            followsPhrase = followsPhrase && fastPhrase.pitch?.midi == Int(midi)
        }
        check("A melodic phrase with thirds and fourths keeps notes sustained beyond confirmation", followsPhrase)

        var alternating = StaffNoteScene(), rejectsAlternating = true
        feed(&alternating, 69, after: 0)
        for midi in [81.0, 57, 81, 57, 81, 57, 81, 57, 69] {
            feed(&alternating, midi)
            rejectsAlternating = rejectsAlternating && alternating.pitch?.midi == 69
        }
        check("Unrelated high and low candidates cannot accumulate into a confirmed jump", rejectsAlternating)

        var vibrato = StaffNoteScene()
        feed(&vibrato, 60, after: 0)
        for midi in [72.0, 73, 72, 73, 72, 73, 72, 73, 72, 73] { feed(&vibrato, midi) }
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
        let heldCount = held.trace.count
        held.receive(audio: audio(held.elapsed)); held.receive(melody: melody(held.elapsed, 57))
        check("Label expiry cannot bypass jump confirmation during continuing sound", held.pitch?.midi == 69 && held.trace.count == heldCount)
        for _ in 0..<8 { feed(&held, 57) }
        check("A sustained new pitch can confirm after the old label expires", held.pitch?.midi == 57 && held.isPitchReliable &&
            abs(held.trace.last!.y - StaffPitch(midi: 57)!.y) < 0.02)

        var interrupted = StaffNoteScene()
        feed(&interrupted, 69, after: 0); feed(&interrupted, 81); feed(&interrupted, 81)
        interrupted.receive(melody: nil); feed(&interrupted, 57)
        check("A brief missing result holds the old note and cannot turn a new jump into an immediate note", interrupted.pitch?.midi == 69 &&
            interrupted.isPitchReliable && interrupted.trace.count == 1)
        for _ in 0..<8 { feed(&interrupted, 57) }
        check("Missing melody clears pending candidates but a confirmed note joins the audible phrase", interrupted.pitch?.midi == 57 &&
            interrupted.trace.first?.segment == interrupted.trace.last?.segment && abs(interrupted.trace.last!.y - StaffPitch(midi: 57)!.y) < 0.02)

        var brokenCandidate = StaffNoteScene()
        feed(&brokenCandidate, 60, after: 0)
        for _ in 0..<4 { feed(&brokenCandidate, 72) }
        feed(&brokenCandidate, 96)
        for _ in 0..<5 { feed(&brokenCandidate, 72) }
        check("A rejected range interrupts candidate continuity rather than joining two short bursts",
            brokenCandidate.pitch?.midi == 60 && brokenCandidate.trace.count == 1)

        var softened = StaffNoteScene()
        feed(&softened, 69, after: 0); feed(&softened, 71)
        let firstTrailY = softened.trace.last!.y
        for _ in 0..<3 { feed(&softened, 71) }
        check("The trail softens its first corner and reaches 95 percent of a small change within 90ms",
            softened.pitch?.midi == 71 && firstTrailY > 74 && firstTrailY < 78 && abs(softened.trace.last!.y - 74) < 0.2 &&
            softened.trace.allSatisfy { (74...78).contains($0.y) })

        var fixedPositions = true
        for midi in StaffPitch.followingMIDI {
            var scene = StaffNoteScene()
            feed(&scene, Double(midi), after: 0)
            let expected = StaffPitch(midi: midi)!.y
            for _ in 0..<60 { feed(&scene, Double(midi), after: 1.0 / 60) }
            fixedPositions = fixedPositions && scene.pitch?.midi == midi && scene.targetY == expected &&
                abs(scene.noteY - expected) < 0.001 && abs(scene.trace.last!.y - expected) < 0.001
        }
        check("Every accepted G2-C6 pitch settles at its fixed absolute treble-staff height", fixedPositions)

        var sameC4 = true, heldStable = true
        for preceding in [43.0, 48, 71, 84] {
            var phrase = StaffNoteScene()
            for _ in 0..<150 { feed(&phrase, preceding, after: 0.02) }
            for _ in 0..<50 { feed(&phrase, 60, after: 0.02) }
            sameC4 = sameC4 && phrase.pitch?.name == "C4" && phrase.targetY == 98 && abs(phrase.noteY - 98) < 0.001
            for _ in 0..<200 {
                feed(&phrase, 60, after: 0.02)
                heldStable = heldStable && phrase.targetY == 98 && abs(phrase.noteY - 98) < 0.001
            }
            phrase.resetInput(clearHistory: true)
            for _ in 0..<50 { feed(&phrase, 60, after: 0.02) }
            sameC4 = sameC4 && phrase.targetY == 98 && abs(phrase.noteY - 98) < 0.001
        }
        check("C4 returns to the same height after low/high phrases and input resets", sameC4)
        check("Holding C4 for four more seconds never recenters the note or its target", heldStable)

        var fixedHistory = StaffNoteScene()
        for _ in 0..<50 { feed(&fixedHistory, 60, after: 0.02) }
        let stored = fixedHistory.trace.last!
        for _ in 0..<150 { feed(&fixedHistory, 48, after: 0.02) }
        let preserved = fixedHistory.trace.first { $0.time == stored.time }
        check("A later low phrase cannot shift existing C4 history or compress its octave distance",
            preserved == stored && abs(stored.y - 98) < 0.001 &&
            abs(fixedHistory.trace.last!.y - stored.y - 28) < 0.001)

        var volume = StaffVolumeTracker()
        volume.receive(envelope: 0.05, time: 0)
        volume.receive(envelope: 0.1, time: 0.02)
        let highContrast = volume.contrast
        for _ in 0..<60 { volume.receive(envelope: 0.1, time: 0.02) }
        check("Repeated snapshots cannot adapt the volume range without new audio", highContrast > 0.7 && volume.contrast == highContrast)
        volume.reset(); volume.receive(envelope: 0.1, time: 0)
        for tick in 1...300 { volume.receive(envelope: 0.1, time: Double(tick) / 50) }
        check("Steady sustained sound does not produce artificial size pulses", volume.contrast == 0.5)
        volume.receive(envelope: .nan, time: 7); volume.receive(envelope: 1, time: .nan)
        check("Invalid audio cannot corrupt the adaptive volume range", volume.contrast == 0.5)

        var pulse = StaffNoteScene()
        pulse.receive(audio: audio(0)); pulse.receive(melody: melody(0, 71))
        pulse.receiveOnset(strength: 1)
        var leftmost = 0.0, rightmost = 0.0, staysOnPitch = true
        for _ in 0..<240 {
            pulse.receive(audio: audio(pulse.elapsed)); pulse.receive(melody: melody(pulse.elapsed, 71))
            pulse.advance(seconds: 1.0 / 120)
            leftmost = min(leftmost, pulse.swayAngle); rightmost = max(rightmost, pulse.swayAngle)
            staysOnPitch = staysOnPitch && pulse.noteY == 74 && pulse.targetY == 74 && pulse.noteCenterX == StaffNoteScene.noteX
        }
        check("One onset sways across both sides and decays back to the center",
            leftmost < -12 * .pi / 180 && rightmost > 3 * .pi / 180 && abs(pulse.swayAngle) < 0.01 * .pi / 180)
        check("Rotational sway keeps the solid head center fixed at its exact staff position", staysOnPitch)
        pulse.receiveOnset(strength: 1); pulse.advance(seconds: 1.0 / 60)
        check("Successive onsets alternate their initial rotation direction", pulse.swayAngle > 0)

        var quiet = StaffNoteScene(), loud = StaffNoteScene()
        var bounded = true, continuous = true, traceIsPitch = true
        for i in 0..<720 {
            let t = Double(i) / 120
            let sharedEnvelope = (i / 60).isMultiple(of: 2) ? 0.05 : 0.1
            quiet.receive(audio: audio(t, envelope: i < 696 ? sharedEnvelope : 0.05))
            loud.receive(audio: audio(t, envelope: i < 696 ? sharedEnvelope : 0.1))
            quiet.receive(melody: melody(t, 66)); loud.receive(melody: melody(t, 66))
            let before = loud.swayAngle
            if i.isMultiple(of: 3) {
                quiet.receiveOnset(strength: 1); loud.receiveOnset(strength: 1)
                continuous = continuous && loud.swayAngle == before && loud.noteCenterX == StaffNoteScene.noteX
            }
            quiet.advance(seconds: 1.0 / 120); loud.advance(seconds: 1.0 / 120)
            bounded = bounded && abs(loud.swayAngle) <= 20 * .pi / 180 && loud.scale <= 1.5 && loud.scale >= 0.8 && loud.noteY == loud.baseY
            traceIsPitch = traceIsPitch && loud.trace.last?.pitch.y == 86 && loud.trace.last?.y == quiet.trace.last?.y
        }
        check("Ordinary musical dynamics visibly change size while preserving pitch and base motion", loud.scale > quiet.scale + 0.2 && loud.baseY == quiet.baseY && loud.targetY == 86)
        check("Dense onsets preserve a fixed pivot, continuous rotation and bounded tilt", bounded && continuous && abs(loud.swayAngle) > 0.0001)
        check("Trace preserves the accepted note and ignores loudness and decorative sway", traceIsPitch)
        check("Trace capacity never exceeds 512 samples", loud.trace.count == 512)
        let point = loud.trace.last!, x = loud.traceX(loud.trace.last!)
        loud.receive(audio: nil); loud.advance(seconds: 1)
        check("History moves left in real time and fades", abs(loud.traceX(point) - (x - 70)) < 1e-8 && loud.traceOpacity(point) < 1)
        loud.advance(seconds: 8)
        check("All history expires after eight seconds, including long scheduling gaps", loud.trace.isEmpty)
        check("Unreliable pitch holds the last height and fades the label", loud.pitch?.name == "F♯4" && loud.targetY == 86 && !loud.isPitchReliable && loud.labelOpacity < 0.02)
        let count = quiet.trace.count
        quiet.receive(melody: nil); quiet.receiveOnset(strength: 1); quiet.advance(seconds: 0.1)
        check("Sound without melody holds pitch, stops history and still follows onsets", quiet.trace.count == count && quiet.targetY == 86 && quiet.canSway && abs(quiet.swayAngle) > 0.0001)
        quiet.receive(audio: audio(8, silent: true)); quiet.receive(melody: melody(8, 60)); quiet.receiveOnset(strength: 1)
        quiet.advance(seconds: 0.25)
        check("Silence stops kicks while existing sway settles smoothly", !quiet.canSway && abs(quiet.swayAngle) < 0.2 * .pi / 180)

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
        check("Stale audio cannot move the note or start actions", simulation.scene.targetY == 98 && !simulation.scene.canSway)
        simulation.update(input: input(1, 67, generation: UUID(), onset: false), deltaTime: 1.0 / 60)
        check("Reconnect isolates old history and accepts the new generation", simulation.scene.trace.count == 1 && simulation.scene.targetY == 82)
        simulation.update(input: input(3, 60, generation: generation, onset: true), deltaTime: 1.0 / 60)
        let oldSway = simulation.scene.swayAngle
        simulation.update(input: input(4, 72, generation: generation, rate: 44_100, channels: 1, onset: true), deltaTime: 1.0 / 60)
        check("Audio format changes discard old history and queued kicks", simulation.scene.trace.count == 1 && simulation.scene.targetY == 70 && abs(simulation.scene.swayAngle) < abs(oldSway))
        simulation.update(input: input(5, 64, generation: generation, time: 0, rate: 44_100, channels: 1), deltaTime: 1.0 / 60)
        check("PCM timeline reset does not connect unrelated trajectories", simulation.scene.trace.count == 1 && simulation.scene.targetY == 90)
        simulation.deactivate()
        simulation.update(input: input(6, 96, generation: generation), deltaTime: 1)
        check("Hidden session stops consuming and clears hidden history", simulation.scene.trace.isEmpty && simulation.scene.targetY == 90)
        simulation.activate(viewport: .desktop)
        simulation.update(input: input(8, 72, generation: generation, age: 1, onset: true), deltaTime: 1.0 / 60)
        check("Resume rejects an expired hidden snapshot", simulation.scene.trace.isEmpty && !simulation.scene.canSway)
        simulation.update(input: input(9, 72, generation: generation), deltaTime: 1.0 / 60)
        check("Resume starts a fresh trajectory from current reliable input", simulation.scene.trace.count == 1 && simulation.scene.targetY == 70)
        simulation.update(input: input(10, 96, generation: generation, state: .recovering, onset: true), deltaTime: 0.2)
        check("Disconnected state holds height and lets existing history fade", simulation.scene.targetY == 70 && simulation.scene.trace.count == 1 && !simulation.scene.canSway)
        var segmented = StaffNoteScene()
        feed(&segmented, 60, after: 0); segmented.receive(melody: nil)
        feed(&segmented, 62)
        check("Brief missing melody keeps the reliable trajectory connected", segmented.trace.count == 2 && segmented.trace[0].segment == segmented.trace[1].segment)

        var vocalPause = StaffNoteScene()
        feed(&vocalPause, 60, after: 0)
        let beforePause = vocalPause.trace
        vocalPause.receive(melody: MelodyFrame(time: 0.02, pitchHz: nil, confidence: 0.1,
                                               isMelodic: false, estimator: .crepe))
        check("Explicit unvoiced singing stops the label, sway and live tail while accompaniment continues",
              !vocalPause.isPitchReliable && !vocalPause.canSway && !vocalPause.hasContinuousTraceTail &&
              vocalPause.trace == beforePause && vocalPause.targetY == 98)
        vocalPause.advance(seconds: 0.2); vocalPause.receive(audio: audio(0.22))
        check("A vocal rest does not create history or reposition the last note", vocalPause.trace == beforePause && vocalPause.labelOpacity < 0.02)
        var returnNote = melody(0.24, 72); returnNote.estimator = .crepe
        vocalPause.receive(melody: returnNote)
        check("Singing resumes at its real pitch and reconnects the visual line across a vocal rest",
              vocalPause.pitch?.midi == 72 && vocalPause.trace.last?.segment == beforePause.last?.segment &&
              abs(vocalPause.trace.last!.y - 70) < 0.01 && vocalPause.trace.count == 2)
        var shortGapsConnect = true, gapsHaveNoTail = true
        for age in [0.0, 0.12, 0.20] {
            for hops in [2, 4, 6] {
                var scene = StaffNoteScene()
                scene.elapse(seconds: age); scene.receive(audio: audio(age))
                scene.receive(melody: singing(0, 60), age: age)
                let initial = scene.trace
                for hop in 1..<hops {
                    scene.advance(seconds: 0.02); scene.receive(audio: audio(scene.elapsed))
                    scene.receive(melody: singing(Double(hop) * 0.02, nil), age: age)
                    gapsHaveNoTail = gapsHaveNoTail && scene.trace == initial && !scene.hasContinuousTraceTail && !scene.canSway
                }
                scene.advance(seconds: 0.02); scene.receive(audio: audio(scene.elapsed))
                scene.receive(melody: singing(Double(hops) * 0.02, 62), age: age)
                shortGapsConnect = shortGapsConnect && scene.trace.count == 2 && scene.targetY == 94 &&
                    scene.trace.first?.segment == scene.trace.last?.segment && scene.hasContinuousTraceTail
            }
        }
        check("40-120ms neural dropouts reconnect real endpoints even with 120-200ms model latency", shortGapsConnect)
        check("Pending neural gaps never append held notes, extend a live tail or allow new sway", gapsHaveNoTail)

        var continuousGaps = true
        for (gap, next) in [(0.14, 60.0), (0.06, 72.0), (0.8, 62.0), (2.0, 67.0)] {
            var scene = StaffNoteScene()
            scene.receive(audio: audio(0)); scene.receive(melody: singing(0, 60))
            let before = scene.trace
            let hops = Int((gap / 0.02).rounded())
            for hop in 1..<hops {
                scene.advance(seconds: 0.02); scene.receive(audio: audio(Double(hop) * 0.02))
                scene.receive(melody: singing(Double(hop) * 0.02, nil))
                continuousGaps = continuousGaps && scene.trace == before && !scene.hasContinuousTraceTail && !scene.isPitchReliable
            }
            scene.advance(seconds: 0.02); scene.receive(audio: audio(gap)); scene.receive(melody: singing(gap, next))
            continuousGaps = continuousGaps && scene.trace.count == 2 && scene.pitch?.midi == Int(next) &&
                scene.trace.first?.segment == scene.trace.last?.segment
        }
        check("Vocal gaps up to two seconds and large note changes preserve a continuous visual contour without invented samples", continuousGaps)

        var confirmedGap = StaffNoteScene()
        confirmedGap.receive(audio: audio(0)); confirmedGap.receive(melody: singing(0, 60))
        confirmedGap.advance(seconds: 0.02); confirmedGap.receive(audio: audio(0.02))
        confirmedGap.receive(melody: singing(0.02, nil))
        for hop in 2...3 {
            confirmedGap.advance(seconds: 0.02); confirmedGap.receive(audio: audio(confirmedGap.elapsed))
            confirmedGap.receive(melody: singing(Double(hop) * 0.02, 64))
        }
        check("A short dropout cannot bypass jump confirmation or revive its tail during confirmation",
            confirmedGap.trace.count == 1 && confirmedGap.pitch?.midi == 60 && !confirmedGap.hasContinuousTraceTail)
        confirmedGap.advance(seconds: 0.02); confirmedGap.receive(audio: audio(0.08))
        confirmedGap.receive(melody: singing(0.08, 64))
        check("A confirmed nearby jump reconnects within the same bounded gap",
            confirmedGap.trace.count == 2 && confirmedGap.pitch?.midi == 64 &&
            confirmedGap.trace.first?.segment == confirmedGap.trace.last?.segment)

        var gapSilence = StaffNoteScene()
        gapSilence.receive(audio: audio(0)); gapSilence.receive(melody: singing(0, 60))
        gapSilence.receive(melody: singing(0.02, nil))
        gapSilence.receive(audio: audio(0.03, silent: true)); gapSilence.receive(audio: audio(0.04))
        gapSilence.receive(melody: singing(0.04, 60))
        check("Raw-audio silence cancels a pending neural bridge immediately",
            gapSilence.trace.count == 2 && gapSilence.trace.first?.segment != gapSilence.trace.last?.segment)
        let beforeOldObservation = gapSilence.trace
        gapSilence.receive(melody: singing(0.02, nil)); gapSilence.receive(melody: singing(0.04, 60))
        check("Duplicate or older unvoiced observations cannot reopen a gap or replay a note",
            gapSilence.trace == beforeOldObservation && gapSilence.isPitchReliable)

        var expiredGap = StaffNoteScene()
        expiredGap.receive(audio: audio(0)); expiredGap.receive(melody: singing(0, 60))
        expiredGap.receive(melody: singing(0.02, nil))
        for _ in 1...25 {
            expiredGap.advance(seconds: 0.02); expiredGap.receive(audio: audio(expiredGap.elapsed))
        }
        expiredGap.receive(melody: singing(0.06, 60))
        check("Stalled pitch with live audio reconnects history without treating the old pitch as reliable",
            expiredGap.trace.count == 2 && expiredGap.trace.first?.segment == expiredGap.trace.last?.segment)
        var staleAudio = StaffNoteScene()
        staleAudio.receive(audio: audio(0)); staleAudio.receive(melody: singing(0, 60))
        staleAudio.advance(seconds: 0.5)
        staleAudio.receive(audio: audio(0.5)); staleAudio.receive(melody: singing(0.5, 60))
        check("An actual audio stall still breaks the visual session",
            staleAudio.trace.count == 2 && staleAudio.trace.first?.segment != staleAudio.trace.last?.segment)
        var expiredHistory = StaffNoteScene()
        expiredHistory.receive(audio: audio(0)); expiredHistory.receive(melody: singing(0, 60))
        for hop in 1...410 {
            let t = Double(hop) * 0.02
            expiredHistory.advance(seconds: 0.02); expiredHistory.receive(audio: audio(t))
            expiredHistory.receive(melody: singing(t, nil))
        }
        check("Continuous music with no pitch still expires all history after eight seconds",
            expiredHistory.trace.isEmpty && !expiredHistory.hasContinuousTraceTail && !expiredHistory.isPitchReliable)
        expiredHistory.receive(melody: singing(8.22, 62))
        check("A return after history expiry draws only the new real point", expiredHistory.trace.count == 1 && expiredHistory.trace[0].pitch.midi == 62)
        var neuralJump = StaffNoteScene()
        feed(&neuralJump, 60, after: 0)
        for i in 1...3 {
            neuralJump.advance(seconds: 0.02); neuralJump.receive(audio: audio(neuralJump.elapsed))
            var next = melody(Double(i) * 0.02, 67); next.estimator = .crepe
            neuralJump.receive(melody: next)
        }
        check("Gated neural pitch confirms a normal leap in 40ms without the old 125ms hold", neuralJump.pitch?.midi == 67)

        let channel = FeatureChannel(), channelID = UUID(), registry = VisualizationRegistry()
        channel.reset(sessionID: channelID, state: .running)
        registry.register(PencilFlightSimulation.module) { PencilFlightSimulation() }
        registry.register(StaffNoteSimulation.module) { StaffNoteSimulation() }
        let controller = VisualizationController(source: channel, registry: registry)
        _ = controller.select(id: "pencil-flight"); controller.resume()
        channel.publish(audio: audio(0), melody: melody(0, 60), sessionID: channelID)
        _ = controller.select(id: "staff-note"); controller.tick(deltaTime: 1.0 / 60)
        let mounted = controller.current as! StaffNoteSimulation
        check("Switch through the real channel consumes current pitch without old bursts", mounted.scene.trace.count == 1 && mounted.scene.swayAngle == 0 && mounted.scene.targetY == 98)
        channel.publish(audio: audio(0.02), melody: melody(0.02, 72), sessionID: channelID)
        controller.tick(deltaTime: 1.0 / 60)
        check("New channel onsets animate immediately while a large pitch jump is pending", mounted.scene.swayAngle < 0 && mounted.scene.targetY == 98)
        for tick in 2...9 {
            let time = Double(tick) * 0.02
            channel.publish(audio: audio(time), melody: melody(time, 72), sessionID: channelID)
            controller.tick(deltaTime: 0.02)
        }
        check("A sustained octave is confirmed through the production feature channel", mounted.scene.targetY == 70)
        controller.pause()
        channel.publish(audio: audio(0.2), melody: melody(0.2, 84), sessionID: channelID)
        let pausedSway = mounted.scene.swayAngle
        controller.resume(); controller.tick(deltaTime: 1.0 / 60)
        check("Hidden channel events are skipped and only current pitch starts fresh history", mounted.scene.trace.count == 1 && mounted.scene.trace[0].pitch.midi == 84 && abs(mounted.scene.swayAngle) < abs(pausedSway))
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
