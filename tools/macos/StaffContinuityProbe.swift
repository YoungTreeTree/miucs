import AppKit

/// Replays saved estimator output through the production simulation and renderer.
/// Constant audible accompaniment isolates visual gaps from raw-audio silence.
@main
@MainActor
enum StaffContinuityProbe {
    struct Manifest: Decodable {
        struct Track: Decodable { let id: String }
        let tracks: [Track]
    }
    struct Point: Codable {
        let time: Double
        let midi: Int
        let y: Double
        let segment: Int
    }
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("Usage: staff-continuity-probe MANIFEST CACHED_FRAMES OUTPUT_DIRECTORY")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let latency = 4096.0 / 48_000 / 2, refresh = 1.0 / 60
        var reports = [[String: Any]]()
        for track in manifest.tracks {
            let frames = try JSONDecoder().decode([MelodyFrame].self,
                from: Data(contentsOf: input.appendingPathComponent(track.id + ".json")))
            guard let end = frames.last?.time else { continue }
            let simulation = StaffNoteSimulation(), session = UUID()
            simulation.activate(viewport: .desktop)
            var index = -1, points = [Point](), lastUpdateTime = 0.0
            var lastPointTime: Double?
            for tick in 1...Int(ceil((end + latency) / refresh)) {
                let now = Double(tick) * refresh
                while index + 1 < frames.count, frames[index + 1].time + latency <= now { index += 1 }
                guard index >= 0 else { continue }
                let melody = frames[index], received = melody.time + latency
                let frame = AudioFeatureFrame(sessionID: session, sequence: UInt64(index + 1), receivedAt: received,
                    audio: StaffNotePreview.audio(received), melody: melody)
                let input = FeatureInput(sessionID: session, state: .running, frame: frame,
                    frameAge: now - received, onsets: [], spectralFluxPeak: 0)
                // Advance the initial empty time as well, so trace times remain in the PCM timeline.
                simulation.update(input: input, deltaTime: now - lastUpdateTime)
                lastUpdateTime = now
                if let point = simulation.scene.trace.last, point.time != lastPointTime {
                    points.append(Point(time: point.time, midi: point.pitch.midi, y: point.y, segment: point.segment))
                    lastPointTime = point.time
                }
            }
            let grouped = Dictionary(grouping: points, by: \.segment)
            let spans = grouped.values.map { $0.last!.time - $0.first!.time }
            let inRange = frames.filter { $0.isMelodic && $0.midi.map { $0 >= 42.5 && $0 < 84.5 } == true }
            let view = StaffNoteView(preview: simulation.scene)
            view.wantsLayer = true; view.updateLayer()
            let root = view.layer!.sublayers!.first!
            let trail = root.sublayers!.first { $0.name == "melody-trail" }!
            let path = (trail.sublayers!.last as! CAShapeLayer).path!
            var subpaths = 0
            path.applyWithBlock { if $0.pointee.type == .moveToPoint { subpaths += 1 } }
            reports.append(["id": track.id, "inputFrames": frames.count, "gatedFramesInStaffRange": inRange.count,
                "framesBelowConfidenceCutoff": inRange.filter { $0.confidence < 0.48 }.count,
                "tracePoints": points.count, "segments": grouped.count,
                "nativeVisibleSubpaths": subpaths,
                "segmentsShorterThan120ms": spans.filter { $0 < 0.12 - 1e-9 }.count])
            try JSONEncoder().encode(points).write(to: output.appendingPathComponent(track.id + ".points.json"))
            if ["fdps_2_01", "geniusturtle_4_01"].contains(track.id) {
                let bitmap = StaffNotePreview.bitmap(scene: simulation.scene, width: 800,
                    background: .white, retainedLayers: true)
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent(track.id + ".png"))
            }
        }
        try JSONSerialization.data(withJSONObject: ["displayHz": 60, "windowCenterAgeSeconds": latency,
            "method": "Saved mixture melody frames; audible accompaniment; production simulation and native vector renderer. Visual continuity only, not a new pitch-accuracy measurement.",
            "tracks": reports], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("Staff continuity replay: \(reports.count) clips → \(output.path)")
    }
}
