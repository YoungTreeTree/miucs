import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Generated music passes through the actual analyzers, staff scene and native vector layers.
/// The sustained opening makes the fixed pivot and volume response visible at one pitch.
@MainActor
enum StaffNoteDemo {
    static let width = 1200, height = 240
    private static let notes = [67.0, 67, 67, 67, 69, 71, 72, 74, 72, 71,
                                69, 67, 66, 64, 62, 64, 67, 67, 67, 67]

    static func render(to output: URL) throws {
        let count = 250, fps = 25.0, warmup = 1000, samplesPerTick = 480
        let rate = 48_000.0
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw AudioAnalysisError.invalidInput("Cannot create staff GIF destination")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        let analysis = try AudioAnalysisPipeline()
        let view = StaffNoteView()
        view.setFrameSize(NSSize(width: width, height: height)); view.wantsLayer = true
        var scene = StaffNoteScene()
        let keyboard = SyntheticKeyboardInput(.demo), keys = MacStaffKeyboardLayout.keys
        let reader = keyboard.channel.subscribe()
        var stars = StaffKeyboardStars(keys: keys)
        var beatRings = StaffBeatRings(seed: 0x42454154), audioSequence: UInt64 = 0, beatCount = 0, ringFrames = 0
        var peakStars = 0, starFrames = 0
        var rendered = 0, onsetCount = 0
        var names = Set<String>()
        var minScale = Double.infinity, maxScale = -Double.infinity
        var minAngle = Double.infinity, maxAngle = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var extrema = [String: StaffNoteScene]()
        var extremaStars = [String: [StaffStar]]()
        var extremaRings = [String: [StaffBeatRing]]()
        var lastMelodyTime: Double?
        for tick in 0..<(warmup + count * 4) {
            var left = [Float](), right = [Float]()
            left.reserveCapacity(samplesPerTick); right.reserveCapacity(samplesPerTick)
            for sample in 0..<samplesPerTick {
                let index = tick * samplesPerTick + sample
                let time = Double(index) / rate
                let beat = time.truncatingRemainder(dividingBy: 0.5)
                let midi = notes[(index / 24_000) % notes.count]
                let hz = 440 * pow(2, (midi - 69) / 12)
                let articulation = max(0, min(1, beat / 0.012, (0.5 - beat) / 0.035))
                let dynamics = 0.065 * pow(10, 0.5 * sin(2 * .pi * time / 2))
                let voice = dynamics * articulation * (sin(2 * .pi * hz * time) +
                    0.45 * sin(4 * .pi * hz * time) + 0.22 * sin(6 * .pi * hz * time))
                left.append(Float(voice)); right.append(Float(voice * 0.96))
            }
            let block = AudioPCMBlock(channels: [left, right], sampleRate: rate, isInterleaved: false)
            var beats = [AudioBeatEvent]()
            for frame in try analysis.process(block) {
                audioSequence += 1
                if let beat = frame.audio.beat, let time = beat.beatTime, let bpm = beat.bpm {
                    beats.append(AudioBeatEvent(sequence: audioSequence, time: time, receivedAt: time,
                        strength: beat.strength, bpm: bpm, confidence: beat.confidence))
                    if tick >= warmup { beatCount += 1 }
                }
                scene.receive(audio: frame.audio)
                if let melody = frame.melody {
                    if melody.time != lastMelodyTime {
                        scene.receive(melody: melody, age: max(0, frame.audio.time - melody.time))
                        lastMelodyTime = melody.time
                    }
                } else { scene.receive(melody: nil) }
                if frame.audio.isOnset {
                    scene.receiveOnset(strength: frame.audio.spectralFlux)
                    if tick >= warmup { onsetCount += 1 }
                }
            }
            scene.advance(seconds: 0.01)
            beatRings.advance(seconds: 0.01, events: beats, now: Double(tick + 1) / 100, through: audioSequence)
            if tick >= warmup {
                keyboard.update(at: Double(tick - warmup) / 100)
                stars.advance(seconds: 0.01, keyboard: reader.read())
            }
            guard tick >= warmup, (tick - warmup) % 4 == 0 else { continue }
            peakStars = max(peakStars, stars.stars.count)
            if stars.hasLiveStars { starFrames += 1 }
            if !beatRings.rings.isEmpty { ringFrames += 1 }
            if let name = scene.pitch?.name { names.insert(name) }
            if scene.scale < minScale { minScale = scene.scale; extrema["small"] = scene; extremaStars["small"] = stars.stars; extremaRings["small"] = beatRings.rings }
            if scene.scale > maxScale { maxScale = scene.scale; extrema["large"] = scene; extremaStars["large"] = stars.stars; extremaRings["large"] = beatRings.rings }
            if scene.swayAngle < minAngle { minAngle = scene.swayAngle; extrema["left"] = scene; extremaStars["left"] = stars.stars; extremaRings["left"] = beatRings.rings }
            if scene.swayAngle > maxAngle { maxAngle = scene.swayAngle; extrema["right"] = scene; extremaStars["right"] = stars.stars; extremaRings["right"] = beatRings.rings }
            minY = min(minY, scene.noteY); maxY = max(maxY, scene.noteY)
            guard scene.noteCenterX == StaffNoteScene.noteX else {
                throw AudioAnalysisError.invalidInput("The staff demo's note pivot moved sideways")
            }
            try autoreleasepool {
                CGImageDestinationAddImage(destination, try draw(scene, stars: stars.stars, rings: beatRings.rings, with: view), properties)
            }
            rendered += 1
        }
        guard rendered == count, names.count >= 6, onsetCount >= 12, maxY - minY > 24,
              maxScale - minScale > 0.25, minAngle < -10 * .pi / 180, maxAngle > 10 * .pi / 180,
              keyboard.rows.count == 5, peakStars > 20, starFrames > 200, beatCount >= 15, ringFrames > 150,
              CGImageDestinationFinalize(destination) else {
            throw AudioAnalysisError.invalidInput("Incomplete staff demo or insufficient visible motion")
        }
        for name in extrema.keys.sorted() {
            let image = try draw(extrema[name]!, stars: extremaStars[name]!, rings: extremaRings[name]!, with: view)
            let path = output.deletingLastPathComponent().appendingPathComponent("\(output.deletingPathExtension().lastPathComponent)-\(name).png")
            try RenderDemo.writePNG(image, to: path)
        }
        let report: [String: Any] = [
            "source": "generated PCM and invented physical key events; production audio analyzers, keyboard channel, star simulation and retained native layers; no capture or event injection",
            "width": width, "height": height, "frames": rendered, "fps": fps,
            "durationSeconds": Double(count) / fps, "loop": "infinite", "background": "plain paper",
            "notes": names.sorted(), "onsets": onsetCount, "noteCenterX": StaffNoteScene.noteX,
            "scaleRange": [minScale, maxScale], "swayDegrees": [minAngle * 180 / .pi, maxAngle * 180 / .pi],
            "notationHeightRange": maxY - minY, "warmupSeconds": Double(warmup) / 100,
            "keyboardPresses": keyboard.presses, "keyboardBursts": stars.totalBursts,
            "keyboardRows": keyboard.rows.sorted(), "framesWithStars": starFrames, "peakStars": peakStars,
            "beats": beatCount, "framesWithBeatRings": ringFrames,
            "animationRateIsPresentationBenchmark": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.deletingPathExtension().appendingPathExtension("json"))
        print("Rendered \(rendered) staff frames, \(names.count) notes, scale \(minScale)...\(maxScale), sway \(minAngle * 180 / .pi)...\(maxAngle * 180 / .pi) degrees")
    }

    private static func draw(_ scene: StaffNoteScene, stars: [StaffStar], rings: [StaffBeatRing], with view: StaffNoteView) throws -> CGImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AudioAnalysisError.invalidInput("Cannot create staff demo bitmap")
        }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let cg = context.cgContext
        cg.translateBy(x: 0, y: Double(height)); cg.scaleBy(x: 1, y: -1)
        DemoDesktop.color(0.975, 0.971, 0.957).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        view.updatePreview(scene, stars: stars, rings: rings); view.updateLayer()
        guard let layer = view.layer else { throw AudioAnalysisError.invalidInput("Missing native staff layers") }
        layer.render(in: cg)
        guard let image = bitmap.cgImage else { throw AudioAnalysisError.invalidInput("Missing staff demo image") }
        return image
    }
}
