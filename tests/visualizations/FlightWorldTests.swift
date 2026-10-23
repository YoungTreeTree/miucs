import Foundation

@main
struct FlightWorldTests {
    static func audio(_ t: Double, onset: Bool = false, silent: Bool = false, amplitude: Double = 0.1) -> AudioFeatures {
        AudioFeatures(time: t, sampleRate: 48_000, channelCount: 2,
                      rms: amplitude, rmsDBFS: 20 * log10(max(amplitude, 1e-12)), peak: amplitude * 2,
                      crestDB: 6, envelope: amplitude, isSilent: silent, silenceDuration: silent ? 1 : 0,
                      lowEnergy: 0.001, midEnergy: 0.003, highEnergy: 0.001,
                      lowShare: 0.2, midShare: 0.6, highShare: 0.2,
                      centroidHz: 2_000, bandwidthHz: 1_500, flatness: 0.2,
                      spectralFlux: onset ? 0.9 : 0.03, onsetThreshold: 0.2, isOnset: onset,
                      balance: 0, sideEnergyRatio: 0.3, correlation: 0.4, displayBands: [])
    }
    static func melody(_ t: Double, _ midi: Double) -> MelodyFrame {
        MelodyFrame(time: t, pitchHz: 440 * pow(2, (midi - 69) / 12), confidence: 1, isMelodic: true)
    }
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ body: () -> (Bool, [String: Any])) {
            let (passed, metrics) = body()
            checks.append(["name": name, "passed": passed, "metrics": metrics])
            print("\(passed ? "PASS" : "FAIL") \(name): \(metrics)")
        }
        check("Pitch order, semitone mapping and octave preservation") {
            var range = MelodyRange()
            let a = range.height(for: melody(0, 60))!, b = range.height(for: melody(0.1, 64))!
            let c = range.height(for: melody(0.2, 67))!, d = range.height(for: melody(0.3, 72))!
            return (a > b && b > c && c > d && abs((a - d) - 140.0 / 3) < 1e-8,
                    ["C4": a, "E4": b, "G4": c, "C5": d])
        }
        check("Adaptive range has an octave floor and bounded movement") {
            var range = MelodyRange(), previous = range.lower, maxStep = 0.0
            var valid = true
            for i in 0..<2400 {
                _ = range.height(for: melody(Double(i) / 40, 67 + sin(Double(i) * 0.1)))
                maxStep = max(maxStep, abs(range.lower - previous)); previous = range.lower
                valid = valid && range.upper - range.lower >= 12 - 1e-9 && maxStep <= 0.7 / 40 + 1e-8
            }
            return (valid, ["spanSemitones": range.upper - range.lower, "maxRangeStep": maxStep])
        }
        check("Live pitch starts moving next frame and settles smoothly within 150ms") {
            var w = SoundFlightWorld(seed: 1), reference = MelodyRange()
            var noInputJump = true, startsImmediately = true, monotone = true, maxRemaining = 0.0
            for (i, note) in [48.0, 84, 60, 72, 72, 40, 96].enumerated() {
                let frame = melody(Double(i) * 0.2, note)
                let before = w.birdY, target = reference.height(for: frame)!
                w.receive(melody: frame)
                noInputJump = noInputJump && w.birdY == before && w.melodyTargetY == target
                var previous = abs(before - target)
                for tick in 0..<9 {
                    w.advance(seconds: 1.0 / 60)
                    let error = abs(w.birdY - target)
                    if tick == 0, previous > 0.01 { startsImmediately = startsImmediately && error < previous }
                    monotone = monotone && error <= previous + 1e-8
                    previous = error
                }
                maxRemaining = max(maxRemaining, previous / max(abs(before - target), 0.01))
                for _ in 0..<30 { w.advance(seconds: 1.0 / 60) }
            }
            return (noInputJump && startsImmediately && monotone && maxRemaining < 0.05 && w.distance == 0,
                    ["noInputTeleport": noInputJump, "startsNextFrame": startsImmediately, "monotone": monotone,
                     "maxRemainingFractionAt150ms": maxRemaining, "distance": w.distance])
        }
        check("Random gates yield smoothly during extreme live pitch jumps") {
            var w = SoundFlightWorld(seed: 42), violations = 0, crossed = 0, moved = Set<Int>()
            var maxBirdStep = 0.0, maxEdgeStep = 0.0, inputJumps = 0
            var previous = [Int: (Double, Double)]()
            func inspect(_ world: SoundFlightWorld) {
                for gate in world.gates {
                    if abs(gate.x - world.distance) <= FlightGate.halfWidth + world.birdHalfWidth {
                        crossed += 1
                        if world.birdY - world.birdHalfHeight - 13 < gate.openingTop || world.birdY + world.birdHalfHeight + 13 > gate.openingBottom { violations += 1 }
                    }
                }
            }
            for i in 0..<60 * 180 {
                let t = Double(i) / 60
                var feature = audio(t, onset: i % 8 == 0, amplitude: (i / 37) % 2 == 0 ? 0.002 : 0.3)
                feature.bandwidthHz = (i / 49) % 2 == 0 ? 150 : 8_000
                w.receive(audio: feature)
                let beforeBird = w.birdY, beforeEdges = w.gates.map(\.openingTop)
                w.receive(melody: melody(t, [40.0, 96, 48, 84, 60, 72][(i / 11) % 6]))
                if w.birdY != beforeBird || w.gates.map(\.openingTop) != beforeEdges { inputJumps += 1 }
                inspect(w)
                w.advance(seconds: 1.0 / 60)
                maxBirdStep = max(maxBirdStep, abs(w.birdY - beforeBird))
                inspect(w)
                for gate in w.gates {
                    if let original = previous[gate.id] {
                        maxEdgeStep = max(maxEdgeStep, abs(original.0 - gate.openingTop), abs(original.1 - gate.openingBottom))
                        if abs(original.0 - gate.openingTop) > 1e-8 { moved.insert(gate.id) }
                    }
                    previous[gate.id] = (gate.openingTop, gate.openingBottom)
                }
            }
            return (violations == 0 && moved.count > 100 && w.score > 200 && crossed > 100 && inputJumps == 0 && maxBirdStep < 28 && maxEdgeStep < 28,
                    ["overlapChecks": crossed, "clearanceViolations": violations, "yieldingGates": moved.count, "score": w.score, "instantInputJumps": inputJumps, "maxBirdStepAt60Hz": maxBirdStep, "maxPipeEdgeStepAt60Hz": maxEdgeStep])
        }
        check("Far gates stay fixed; dense random spacing does not require onsets") {
            var w = SoundFlightWorld(seed: 42), seen = Set<Int>(), positions = [Double](), centers = [Double]()
            var previous = [Int: Double](), farChanges = 0
            for i in 0..<60 * 20 {
                let t = Double(i) / 60
                w.receive(audio: audio(t))
                w.receive(melody: melody(t, 48 + 36 * Double(i % 2)))
                w.advance(seconds: 1.0 / 60)
                for gate in w.gates {
                    if seen.insert(gate.id).inserted {
                        positions.append(gate.x); centers.append((gate.openingTop + gate.openingBottom) / 2)
                    }
                    if gate.x - w.distance >= 220, let top = previous[gate.id], abs(top - gate.openingTop) > 1e-8 { farChanges += 1 }
                    previous[gate.id] = gate.openingTop
                }
            }
            let spacing = zip(positions.dropFirst(), positions).map { $0 - $1 }
            return (farChanges == 0 && positions.count > 25 && (spacing.min() ?? 0) >= 74 && (spacing.max() ?? 999) < 94 && Set(centers).count == centers.count && w.flap == 0,
                    ["generatedWithoutOnsets": positions.count, "minimumSpacing": spacing.min() ?? 0, "maximumSpacing": spacing.max() ?? 0, "farGateChanges": farChanges])
        }
        check("Envelope gain changes bird size smoothly without changing height") {
            var quiet = SoundFlightWorld(), loud = SoundFlightWorld()
            var maxStep = 0.0
            for i in 0..<600 {
                let t = Double(i) / 60, m = melody(t, 72)
                let previous = loud.birdScale
                quiet.receive(audio: audio(t, onset: i % 30 == 0, amplitude: 0.01)); quiet.receive(melody: m)
                loud.receive(audio: audio(t, onset: i % 30 == 0, amplitude: 0.3)); loud.receive(melody: m)
                quiet.advance(seconds: 1.0 / 60); loud.advance(seconds: 1.0 / 60)
                maxStep = max(maxStep, abs(loud.birdScale - previous))
            }
            return (abs(quiet.birdY - loud.birdY) < 1e-9 && loud.loudness > quiet.loudness && loud.birdScale > quiet.birdScale + 0.3 && loud.birdScale <= 1.4 && maxStep < 0.04,
                    ["heightDifference": abs(quiet.birdY - loud.birdY), "quietScale": quiet.birdScale, "loudScale": loud.birdScale, "maxScaleStepAt60Hz": maxStep])
        }
        check("Spectral bandwidth controls pipe lead without changing pitch or bird size") {
            var narrow = SoundFlightWorld(seed: 42), wide = SoundFlightWorld(seed: 42)
            var leads = [[Double](), [Double]()], lastIDs = [-1, -1]
            for i in 0..<1200 {
                let t = Double(i) / 60
                var low = audio(t), high = low
                low.bandwidthHz = 200; high.bandwidthHz = 6_000
                narrow.receive(audio: low); wide.receive(audio: high)
                narrow.receive(melody: melody(t, 67)); wide.receive(melody: melody(t, 67))
                narrow.advance(seconds: 1.0 / 60); wide.advance(seconds: 1.0 / 60)
                for (index, scene) in [narrow, wide].enumerated() {
                    if let gate = scene.gates.last, gate.id != lastIDs[index] {
                        if i > 300 { leads[index].append(gate.x - scene.distance) }
                        lastIDs[index] = gate.id
                    }
                }
            }
            let close = leads[0].reduce(0, +) / Double(leads[0].count)
            let far = leads[1].reduce(0, +) / Double(leads[1].count)
            return (close < 210 && far > 285 && wide.birdY == narrow.birdY && wide.birdScale == narrow.birdScale && wide.distance == narrow.distance,
                    ["narrowPipeLead": close, "widePipeLead": far, "sameBirdHeightAndSize": wide.birdY == narrow.birdY && wide.birdScale == narrow.birdScale])
        }
        check("Rapid bandwidth changes preserve pipe ordering and minimum spacing") {
            var w = SoundFlightWorld(seed: 42), minimum = Double.infinity, maxLeadStep = 0.0
            var safe = true
            for i in 0..<3600 {
                var feature = audio(Double(i) / 60)
                feature.bandwidthHz = (i / 12) % 3 == 0 ? nil : ((i / 12) % 3 == 1 ? 0 : 20_000)
                let previous = w.gateLeadDistance
                w.receive(audio: feature); w.advance(seconds: 1.0 / 60)
                maxLeadStep = max(maxLeadStep, abs(w.gateLeadDistance - previous))
                for pair in zip(w.gates, w.gates.dropFirst()) {
                    let spacing = pair.1.x - pair.0.x
                    minimum = min(minimum, spacing); safe = safe && spacing >= 74 - 1e-8
                }
            }
            return (safe && maxLeadStep < 4 && w.score > 60,
                    ["minimumSpacing": minimum, "maximumLeadStepAt60Hz": maxLeadStep, "score": w.score])
        }
        check("Spectral flux emits bounded gas puffs independently of onset") {
            var stable = SoundFlightWorld(seed: 1), changing = SoundFlightWorld(seed: 1)
            var strongest = 0.0, maxCount = 0, produced = Set<Int>()
            for i in 0..<600 {
                let t = Double(i) / 60
                var quiet = audio(t), flux = quiet
                quiet.spectralFlux = 0.03; flux.spectralFlux = i < 300 ? 0.15 : 0.9
                stable.receive(audio: quiet); changing.receive(audio: flux)
                stable.advance(seconds: 1.0 / 60); changing.advance(seconds: 1.0 / 60)
                maxCount = max(maxCount, changing.puffs.count)
                for puff in changing.puffs { produced.insert(puff.id); strongest = max(strongest, puff.strength) }
            }
            return (stable.puffs.isEmpty && produced.count > 40 && produced.count < 80 && maxCount <= 6 && strongest == 1 && changing.flap == 0 && changing.particles.allSatisfy { !$0.feather },
                    ["emittedPuffs": produced.count, "maxConcurrentPuffs": maxCount, "strongestPuff": strongest, "flapWithoutOnsets": changing.flap])
        }
        check("Silence and missing frames cannot replay gas bursts") {
            var w = SoundFlightWorld(seed: 1), frame = audio(0)
            frame.spectralFlux = 0.8
            w.receive(audio: frame); w.advance(seconds: 1.0 / 60)
            let emitted = !w.puffs.isEmpty
            for _ in 0..<120 { w.advance(seconds: 1.0 / 60) }
            let expired = w.puffs.isEmpty
            frame.time = 3; frame.isSilent = true
            w.receive(audio: frame); w.advance(seconds: 0.1)
            w.receive(audio: nil); w.advance(seconds: 0.1)
            return (emitted && expired && w.puffs.isEmpty,
                    ["firstBurstEmitted": emitted, "staleBurstExpired": expired, "noSilentBurst": w.puffs.isEmpty])
        }
        check("Silence and disconnect coast to an exact stop") {
            var w = SoundFlightWorld()
            for i in 0..<300 { w.receive(audio: audio(Double(i) / 60)); w.advance(seconds: 1.0 / 60) }
            w.receive(audio: nil)
            for _ in 0..<300 { w.advance(seconds: 1.0 / 60) }
            let d = w.distance, score = w.score, gates = w.gates.count
            for _ in 0..<120 { w.advance(seconds: 1.0 / 60) }
            return (w.distance == d && w.score == score && w.gates.count == gates && w.activity == 0,
                    ["distanceAfterStop": d, "activity": w.activity])
        }
        check("No melody retains height; stale onset is not replayed") {
            var w = SoundFlightWorld(), heldHeight = 0.0
            for i in 0..<600 {
                let t = Double(i) / 60
                w.receive(audio: audio(t, onset: i == 0))
                if i < 180 { w.receive(melody: melody(t, 67)) }
                else { w.receive(melody: MelodyFrame(time: t, pitchHz: nil, confidence: 0, isMelodic: false)) }
                w.advance(seconds: 1.0 / 60)
                if i == 179 { heldHeight = w.birdY }
            }
            return (abs(w.birdY - heldHeight) < 0.001 && w.score > 5 && w.flap < 0.001 && w.birdY.isFinite,
                    ["score": w.score, "flap": w.flap, "heldHeight": w.birdY])
        }
        check("Trailing note preserves absolute name, accidentals and octave") {
            var w = SoundFlightWorld(seed: 1), actual = [String]()
            for (i, midi) in [48.0, 60, 61, 69, 71, 72, 84].enumerated() {
                let t = Double(i) / 60
                w.receive(audio: audio(t)); w.receive(melody: melody(t, midi))
                actual.append(w.melodyNoteName ?? "nil")
                w.advance(seconds: 1.0 / 60)
            }
            let expected = ["C3", "C4", "C♯4", "A4", "B4", "C5", "C6"]
            return (actual == expected, ["actual": actual, "expected": expected])
        }
        check("Note label resists boundary chatter and expires on missing melody") {
            var w = SoundFlightWorld(seed: 1)
            w.receive(audio: audio(0)); w.receive(melody: melody(0, 60))
            w.receive(melody: melody(0.02, 60.55))
            let held = w.melodyNoteName == "C4"
            w.receive(melody: melody(0.04, 60.7))
            let changed = w.melodyNoteName == "C♯4"
            w.receive(melody: melody(0.06, 60.45))
            let stable = w.melodyNoteName == "C♯4"
            w.advance(seconds: 0.15)
            let fading = w.melodyNoteName != nil && w.melodyNoteOpacity < 0.88
            w.receive(audio: audio(0.2)); w.advance(seconds: 0.1)
            let expired = w.melodyNoteName == nil
            w.receive(melody: melody(0.3, 72)); w.receive(audio: audio(0.3, silent: true))
            let silent = w.melodyNoteName == nil
            w.receive(audio: nil)
            return (held && changed && stable && fading && expired && silent && w.melodyNoteName == nil,
                    ["boundaryHeld": held && stable, "changedAtNewNote": changed, "fades": fading,
                     "missingMelodyClears": expired, "silenceClears": silent])
        }
        check("Identical input gives identical scene") {
            func run() -> SoundFlightWorld {
                var w = SoundFlightWorld(seed: 123)
                for i in 0..<600 {
                    let t = Double(i) / 60
                    w.receive(audio: audio(t, onset: i % 24 == 0)); w.receive(melody: melody(t, 60 + sin(t) * 12))
                    w.advance(seconds: 1.0 / 60)
                }
                return w
            }
            let a = run(), b = run()
            return (a.distance == b.distance && a.birdY == b.birdY && a.score == b.score && a.particles.map(\.y) == b.particles.map(\.y) && a.puffs.map(\.x) == b.puffs.map(\.x) && a.gates.map(\.openingTop) == b.gates.map(\.openingTop),
                    ["score": a.score, "particleCount": a.particles.count])
        }
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        let report: [String: Any] = ["passed": checks.count - failures, "failed": failures, "checks": checks]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/flight-world-tests.json"))
        if failures > 0 { exit(1) }
    }
}
