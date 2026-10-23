import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Offline, deterministic demo. No screen capture, microphone, player or desktop access.
/// The production analyzers, world and drawing view consume generated PCM only.
@main
@MainActor
enum RenderDemo {
    static let rate = 48_000.0
    static let notes = [60.0, 64, 67, 72, 76, 72, 67, 64, 57, 62, 66, 69, 74, 69, 64, 60]

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--desktop") else {
            throw AudioAnalysisError.invalidInput("Usage: render-demo <output.gif> [--desktop]")
        }
        let desktop = arguments.count == 3
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let count = 250, fps = 25.0, warmup = 300, samplesPerTick = 480
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw AudioAnalysisError.invalidInput("Cannot create GIF destination")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        let analysis = try AudioAnalysisPipeline()
        var world = SoundFlightWorld(seed: 42)
        var noteNames = Set<String>(), low = Double.infinity, high = -Double.infinity
        var firstScore = 0, rendered = 0
        for tick in 0..<(warmup + count * 4) {
            var left = [Float](), right = [Float]()
            left.reserveCapacity(samplesPerTick); right.reserveCapacity(samplesPerTick)
            for sample in 0..<samplesPerTick {
                let index = tick * samplesPerTick + sample
                let t = Double(index) / rate
                let beat = t.truncatingRemainder(dividingBy: 0.5)
                let midi = notes[(index / 24_000) % notes.count]
                let hz = 440 * pow(2, (midi - 69) / 12)
                let envelope = max(0, min(1, beat / 0.012, (0.5 - beat) / 0.035))
                let gain = 0.11 * (0.85 + 0.15 * sin(2 * .pi * t / 4)) * envelope
                let voice = gain * (sin(2 * .pi * hz * t) + 0.45 * sin(4 * .pi * hz * t) + 0.22 * sin(6 * .pi * hz * t))
                let bass = 0.035 * exp(-beat / 0.13) * sin(2 * .pi * 65.4064 * t)
                let hash = UInt64(index) &* 6364136223846793005 &+ 1442695040888963407
                let noise = (Double(hash >> 32) / Double(UInt32.max) * 2 - 1) * 0.035 * exp(-beat / 0.025)
                left.append(Float(voice + bass + noise))
                right.append(Float(voice * 0.96 + bass - noise * 0.7))
            }
            let block = AudioPCMBlock(channels: [left, right], sampleRate: rate, isInterleaved: false)
            for frame in try analysis.process(block) {
                world.receive(audio: frame.audio)
                world.receive(melody: frame.melody)
            }
            world.advance(seconds: 0.01)
            guard tick >= warmup, (tick - warmup) % 4 == 0 else { continue }
            if rendered == 0 { firstScore = world.score }
            if let name = world.melodyNoteName { noteNames.insert(name) }
            low = min(low, world.birdY); high = max(high, world.birdY)
            // Only this offscreen bitmap can become a frame; no window or display is read.
            try autoreleasepool {
                let view = PencilFlightView(preview: world)
                let image = try draw(view, desktop: desktop, time: Double(rendered) / fps)
                if desktop && rendered == 0 {
                    try writePNG(image, to: output.deletingPathExtension().appendingPathExtension("first.png"))
                }
                CGImageDestinationAddImage(destination, image, properties)
            }
            rendered += 1
        }
        guard rendered == count, noteNames.count >= 6, high - low > 35, world.score - firstScore >= 8,
              CGImageDestinationFinalize(destination) else {
            throw AudioAnalysisError.invalidInput("Incomplete demo or insufficient visible motion")
        }
        if desktop {
            let background = try draw(nil, desktop: true, time: 0)
            let backgroundURL = output.deletingPathExtension().appendingPathExtension("background.png")
            try writePNG(background, to: backgroundURL)
        }
        let report: [String: Any] = ["source": "generated PCM, production analyzers and renderer; no desktop recording",
                                    "width": desktop ? DemoDesktop.width : 640, "height": desktop ? DemoDesktop.height : 416,
                                    "background": desktop ? "procedural empty desktop; illustrated cursor and selection" : "plain paper",
                                    "frames": rendered, "fps": fps,
                                    "durationSeconds": Double(count) / fps, "loop": "infinite",
                                    "notes": noteNames.sorted(), "birdHeightRange": high - low,
                                    "gatesPassed": world.score - firstScore]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.deletingPathExtension().appendingPathExtension("json"))
        print("Rendered \(rendered) isolated frames, \(noteNames.count) note names, \(world.score - firstScore) gate passes")
    }

    static func writePNG(_ image: CGImage, to output: URL) throws {
        guard let png = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AudioAnalysisError.invalidInput("Cannot create verification image")
        }
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png) else { throw AudioAnalysisError.invalidInput("Incomplete verification image") }
    }

    static func draw(_ view: PencilFlightView?, desktop: Bool, time: Double) throws -> CGImage {
        let width = desktop ? DemoDesktop.width : 640, height = desktop ? DemoDesktop.height : 416
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AudioAnalysisError.invalidInput("Cannot create demo bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let cg = context.cgContext
        cg.translateBy(x: 0, y: Double(height)); cg.scaleBy(x: 1, y: -1)
        if desktop {
            DemoDesktop.drawBackground()
            DemoDesktop.drawSelection(at: time)
            if let view {
                NSGraphicsContext.saveGraphicsState()
                cg.clip(to: DemoDesktop.widget)
                cg.translateBy(x: DemoDesktop.widget.minX, y: DemoDesktop.widget.minY)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            DemoDesktop.drawCursor(at: time)
        } else {
            DemoDesktop.color(0.975, 0.971, 0.957).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            cg.scaleBy(x: 1.6, y: 1.6)
            if let view { view.draw(view.bounds) }
        }
        guard let image = bitmap.cgImage else { throw AudioAnalysisError.invalidInput("Missing demo image") }
        return image
    }
}
