import AppKit

/// Reproducible vector previews from invented notes; never captures the user's screen/audio.
@MainActor
enum StaffNotePreview {
    static func audio(_ t: Double, silent: Bool = false) -> AudioFeatures {
        AudioFeatures(time: t, sampleRate: 48_000, channelCount: 2,
            rms: 0.1, rmsDBFS: -20, peak: 0.2, crestDB: 6, envelope: 0.1,
            isSilent: silent, silenceDuration: silent ? 1 : 0,
            lowEnergy: 0.001, midEnergy: 0.003, highEnergy: 0.001,
            lowShare: 0.2, midShare: 0.6, highShare: 0.2, centroidHz: 2000, bandwidthHz: 1500,
            flatness: 0.2, spectralFlux: 0.8, onsetThreshold: 0.2, isOnset: false,
            balance: 0, sideEnergyRatio: 0.1, correlation: 0.8, displayBands: [])
    }
    static func melody(_ t: Double, midi: Double) -> MelodyFrame {
        MelodyFrame(time: t, pitchHz: 440 * pow(2, (midi - 69) / 12), confidence: 1, isMelodic: true)
    }
    static func sampleScene(midi: Double? = nil) -> StaffNoteScene {
        var scene = StaffNoteScene()
        for tick in 0..<480 {
            let t = Double(tick) / 60
            let note = midi ?? [60.0, 62, 64, 67, 69, 72, 74, 72, 69, 67, 66, 69, 67, 64, 62, 66][tick / 30]
            scene.receive(audio: audio(t)); scene.receive(melody: melody(t, midi: note))
            if tick.isMultiple(of: 30) { scene.receiveOnset(strength: 0.8) }
            scene.advance(seconds: 1.0 / 60)
        }
        return scene
    }
    static func bitmap(scene: StaffNoteScene, width: Int, background: NSColor? = nil,
                       retainedLayers: Bool = false, stars: [StaffStar] = [], rings: [StaffBeatRing] = [],
                       appearance: VisualizationAppearance = .graphite) -> NSBitmapImageRep {
        let height = width / 5
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        let view = StaffNoteView(preview: scene)
        view.updatePreview(scene, stars: stars, rings: rings); view.applyAppearance(appearance)
        view.setFrameSize(NSSize(width: width, height: height))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: width * 2, height: height * 2))
        cg.translateBy(x: 0, y: Double(height * 2)); cg.scaleBy(x: 2, y: -2)
        if let background {
            cg.setFillColor(background.cgColor); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if retainedLayers {
            view.wantsLayer = true
            view.updateLayer()
            view.layer!.render(in: cg)
        } else {
            view.draw(view.bounds)
        }
        return bitmap
    }
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = sampleScene()
        for width in [600, 800, 1600] {
            for (name, color) in [("transparent", nil), ("light", NSColor(calibratedWhite: 0.96, alpha: 1)),
                                   ("dark", NSColor(calibratedWhite: 0.12, alpha: 1))] as [(String, NSColor?)] {
                let b = bitmap(scene: scene, width: width, background: color)
                try b.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("staff-\(width)-\(name).png"))
            }
        }
        for (name, scene) in [("G2", sampleScene(midi: 43)), ("C6", sampleScene(midi: 84)), ("idle", StaffNoteScene())] {
            try bitmap(scene: scene, width: 800).representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent("staff-\(name).png"))
        }
        print("Staff previews: \(directory.path)")
    }
}
