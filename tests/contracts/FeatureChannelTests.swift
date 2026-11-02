import Foundation
import Dispatch

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 100.0
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

private func sample(_ time: Double = 0, onset: Bool = false, flux: Double = 0) -> AudioFeatures {
    AudioFeatures(time: time, sampleRate: 48_000, channelCount: 2, rms: 0.1, rmsDBFS: -20,
        peak: 0.2, crestDB: 6.0206, envelope: 0.1, isSilent: false, silenceDuration: 0,
        lowEnergy: 0.005, midEnergy: 0.003, highEnergy: 0.002, lowShare: 0.5, midShare: 0.3,
        highShare: 0.2, centroidHz: 2000, bandwidthHz: 1500, flatness: 0.1,
        spectralFlux: flux, onsetThreshold: 0.18, isOnset: onset,
        balance: 0, sideEnergyRatio: 0.1, correlation: 0.8, displayBands: Array(repeating: 0.2, count: 24))
}

@MainActor
private final class ProbeSession: VisualizationSession {
    let descriptor: VisualizationDescriptor
    var inputs = [FeatureInput]()
    var viewport = VisualizationViewport.desktop
    var active = false
    var disposals = 0
    init(_ descriptor: VisualizationDescriptor) { self.descriptor = descriptor }
    func activate(viewport: VisualizationViewport) { active = true; self.viewport = viewport }
    func update(input: FeatureInput, deltaTime: Double) { precondition(active); inputs.append(input) }
    func resize(to viewport: VisualizationViewport) { self.viewport = viewport }
    func deactivate() { active = false }
    func dispose() { active = false; disposals += 1 }
}

@main
@MainActor
enum FeatureChannelTests {
    static func main() throws {
        var checks = [[String: Any]]()
        func check(_ name: String, _ test: () throws -> Bool) rethrows {
            let passed = try test()
            print("\(passed ? "PASS" : "FAIL") \(name)")
            checks.append(["name": name, "passed": passed])
        }
        func setup() -> (FeatureChannel, TestClock, UUID) {
            let clock = TestClock(), id = UUID()
            let channel = FeatureChannel(now: { clock.value })
            channel.reset(sessionID: id, state: .running)
            return (channel, clock, id)
        }

        try check("Language-neutral fixtures decode and round-trip through the runtime contract") {
            let input = URL(fileURLWithPath: "contracts/audio-features/samples")
            let output = URL(fileURLWithPath: "build/contracts/round-trip")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            for file in files {
                let batch = try JSONDecoder().decode(FeatureInput.self, from: Data(contentsOf: file))
                guard batch.version == 1, batch.frame?.version ?? 1 == 1 else { return false }
                let data = try JSONEncoder().encode(batch)
                try data.write(to: output.appendingPathComponent(file.lastPathComponent))
                let back = try JSONDecoder().decode(FeatureInput.self, from: data)
                guard back.sessionID == batch.sessionID, back.state == batch.state,
                      back.frame?.audio.time == batch.frame?.audio.time,
                      back.onsets.count == batch.onsets.count,
                      back.beats?.count == batch.beats?.count,
                      back.frame?.audio.beat?.bpm == batch.frame?.audio.beat?.bpm else { return false }
            }
            return files.count >= 5
        }
        check("Continuous backlog keeps only the newest frame") {
            let (channel, _, id) = setup(), reader = channel.subscribe()
            for i in 0..<1000 { channel.publish(audio: sample(Double(i)), melody: nil, sessionID: id) }
            let input = reader.read()
            return input.frame?.sequence == 1000 && input.frame?.audio.time == 999 && input.onsets.isEmpty
        }
        func beatSample(_ time: Double, pulse: Double? = nil, confidence: Double = 0.9) -> AudioFeatures {
            var a = sample(time)
            a.beat = BeatFrame(time: time, bpm: 120, phase: 0, confidence: confidence, strength: 0.8, beatTime: pulse ?? time)
            return a
        }
        check("Beats survive intervening snapshots, drain independently and are not replayed to new readers") {
            let (channel, _, id) = setup(), a = channel.subscribe(), b = channel.subscribe()
            channel.publish(audio: beatSample(1), melody: nil, sessionID: id)
            channel.publish(audio: sample(1.02), melody: nil, sessionID: id)
            return a.read().beats?.count == 1 && b.read().beats?.count == 1 && a.read().beats?.isEmpty == true &&
                channel.subscribe().read().beats?.isEmpty == true
        }
        check("Duplicate, old, future and unreliable beats cannot enqueue pulses") {
            let (channel, _, id) = setup(), reader = channel.subscribe()
            for a in [beatSample(1), beatSample(1.02, pulse: 1), beatSample(1.2, pulse: 1.05),
                      beatSample(1.3, pulse: 2), beatSample(1.4, confidence: 0.4)] {
                channel.publish(audio: a, melody: nil, sessionID: id)
            }
            return reader.read().beats?.map(\.time) == [1]
        }
        check("Beat queue is bounded and ages by the detected pulse timestamp") {
            let (channel, clock, id) = setup(), reader = channel.subscribe()
            for n in 1...100 { channel.publish(audio: beatSample(Double(n)), melody: nil, sessionID: id) }
            let bounded = reader.read().beats?.map(\.sequence) == Array(UInt64(37)...100)
            channel.publish(audio: beatSample(101, pulse: 100.94), melody: nil, sessionID: id)
            clock.value += 0.20
            return bounded && reader.read().beats?.isEmpty == true
        }
        check("Silence, transport loss, format change and reconnection clear queued beat pulses") {
            let (channel, _, id) = setup(), reader = channel.subscribe()
            channel.publish(audio: beatSample(1), melody: nil, sessionID: id)
            var silent = sample(1.02); silent.isSilent = true
            channel.publish(audio: silent, melody: nil, sessionID: id)
            var ok = reader.read().beats?.isEmpty == true
            channel.publish(audio: beatSample(2), melody: nil, sessionID: id); channel.setState(.recovering)
            ok = ok && reader.read().beats?.isEmpty == true
            channel.setState(.running); channel.publish(audio: beatSample(3), melody: nil, sessionID: id)
            var format = sample(0); format.channelCount = 1
            channel.publish(audio: format, melody: nil, sessionID: id)
            ok = ok && reader.read().beats?.isEmpty == true
            channel.publish(audio: beatSample(1), melody: nil, sessionID: id)
            channel.reset(sessionID: UUID(), state: .connecting)
            return ok && reader.read().beats?.isEmpty == true
        }
        check("Onset backlog is ordered and capped at 64 newest events") {
            let (channel, clock, id) = setup(), reader = channel.subscribe()
            for i in 1...100 {
                clock.value = 100 + Double(i) / 1000
                channel.publish(audio: sample(Double(i), onset: true, flux: 0.4), melody: nil, sessionID: id)
            }
            let input = reader.read()
            return input.onsets.map(\.sequence) == Array(UInt64(37)...100) && reader.read().onsets.isEmpty
        }
        check("Events expire after 250ms; continuous state reports its age") {
            let (channel, clock, id) = setup(), reader = channel.subscribe()
            channel.publish(audio: sample(onset: true, flux: 0.9), melody: nil, sessionID: id)
            clock.value += 0.251
            let input = reader.read()
            return input.onsets.isEmpty && input.spectralFluxPeak == 0 && (input.frameAge ?? 0) > 0.25
        }
        check("Interval flux peak survives a quieter latest snapshot and more than 64 frames") {
            let (channel, _, id) = setup(), reader = channel.subscribe()
            channel.publish(audio: sample(flux: 0.9), melody: nil, sessionID: id)
            for i in 1...500 { channel.publish(audio: sample(Double(i), flux: 0.01), melody: nil, sessionID: id) }
            let input = reader.read()
            return input.spectralFluxPeak == 0.9 && input.frame?.audio.spectralFlux == 0.01 && reader.read().spectralFluxPeak == 0
        }
        check("Readers drain independently and new readers never replay old bursts") {
            let (channel, _, id) = setup(), a = channel.subscribe(), b = channel.subscribe()
            channel.publish(audio: sample(onset: true, flux: 0.8), melody: nil, sessionID: id)
            let first = a.read(), second = b.read(), newcomer = channel.subscribe().read()
            return first.onsets.count == 1 && second.onsets.count == 1 && a.read().onsets.isEmpty &&
                newcomer.onsets.isEmpty && newcomer.spectralFluxPeak == 0 && newcomer.frame?.sequence == 1
        }
        check("Silent frames cannot enqueue onsets or flux effects") {
            let (channel, _, id) = setup(), reader = channel.subscribe()
            var silent = sample(onset: true, flux: 1); silent.isSilent = true
            channel.publish(audio: silent, melody: nil, sessionID: id)
            let input = reader.read()
            return input.onsets.isEmpty && input.spectralFluxPeak == 0 && input.frame?.audio.isSilent == true
        }
        check("Reconnect clears old data, rejects late callbacks, and restarts sequence numbers") {
            let (channel, _, oldID) = setup(), reader = channel.subscribe(), nextID = UUID()
            channel.publish(audio: sample(onset: true, flux: 0.9), melody: nil, sessionID: oldID)
            channel.reset(sessionID: nextID, state: .connecting)
            let empty = reader.read()
            let rejected = !channel.publish(audio: sample(), melody: nil, sessionID: oldID)
            let notRunning = !channel.publish(audio: sample(), melody: nil, sessionID: nextID)
            channel.setState(.running)
            channel.publish(audio: sample(0, onset: true, flux: 0.2), melody: nil, sessionID: nextID)
            let current = reader.read()
            return empty.frame == nil && empty.onsets.isEmpty && empty.spectralFluxPeak == 0 && rejected && notRunning &&
                current.sessionID == nextID && current.frame?.sequence == 1 && current.onsets.count == 1 && current.spectralFluxPeak == 0.2
        }
        check("Diagnostic tap records every frame independently of display reads and stays bounded") {
            let (channel, _, id) = setup()
            channel.publish(audio: sample(), melody: nil, sessionID: id)
            let initiallyDisabled = channel.recordedFrameCount == 0
            channel.startRecording()
            for i in 0..<10_020 { channel.publish(audio: sample(Double(i)), melody: nil, sessionID: id) }
            let retained = channel.stopRecording()
            channel.publish(audio: sample(), melody: nil, sessionID: id)
            return initiallyDisabled && retained.count == 10_000 && retained.first?.sequence == 22 &&
                retained.last?.sequence == 10_021 && channel.recordedFrameCount == 0
        }
        check("Concurrent publication and reads remain coherent and keep the event bound") {
            let (channel, _, id) = setup(), reader = channel.subscribe()
            DispatchQueue.concurrentPerform(iterations: 2000) { i in
                channel.publish(audio: sample(Double(i), onset: true, flux: 0.2), melody: nil, sessionID: id)
                let input = reader.read()
                precondition(input.sessionID == id && input.onsets.count <= 64)
                precondition(input.onsets.allSatisfy { $0.sequence <= input.frame!.sequence })
            }
            return channel.snapshot?.sequence == 2000
        }
        check("Registry switches sessions, drops pending bursts, and leaves the source generation intact") {
            let (channel, _, id) = setup(), registry = VisualizationRegistry()
            let first = ProbeSession(VisualizationDescriptor(id: "first", name: "First"))
            let second = ProbeSession(VisualizationDescriptor(id: "second", name: "Second"))
            registry.register(first.descriptor) { first }; registry.register(second.descriptor) { second }
            let controller = VisualizationController(source: channel, registry: registry)
            guard controller.select(id: "first") else { return false }
            controller.resume()
            channel.publish(audio: sample(onset: true, flux: 0.8), melody: nil, sessionID: id)
            guard controller.select(id: "second") else { return false }
            controller.tick(deltaTime: 1.0 / 60)
            let input = second.inputs.last!
            let switched = !first.active && first.disposals == 1 && second.active &&
                input.onsets.isEmpty && input.spectralFluxPeak == 0 && input.frame?.sequence == 1 && input.sessionID == id
            channel.publish(audio: sample(1, onset: true, flux: 0.4), melody: nil, sessionID: id)
            controller.tick(deltaTime: 1.0 / 60)
            let live = second.inputs.last?.onsets.count == 1 && channel.currentState == .running
            controller.dispose()
            return switched && live && second.disposals == 1 && !second.active && controller.current == nil
        }
        check("Same or unknown module selection preserves the current session and its pending events") {
            let (channel, _, id) = setup(), registry = VisualizationRegistry()
            let session = ProbeSession(VisualizationDescriptor(id: "test", name: "Test"))
            registry.register(session.descriptor) { session }
            let controller = VisualizationController(source: channel, registry: registry)
            controller.select(id: "test"); controller.resume()
            channel.publish(audio: sample(onset: true), melody: nil, sessionID: id)
            let selected = controller.select(id: "test"), unknown = controller.select(id: "unknown")
            controller.tick(deltaTime: 0.01)
            return selected && !unknown && session.disposals == 0 && session.inputs.last?.onsets.count == 1
        }
        check("Pause drops hidden-time events on resume and forwards the new viewport") {
            let (channel, _, id) = setup(), registry = VisualizationRegistry()
            let session = ProbeSession(VisualizationDescriptor(id: "test", name: "Test"))
            registry.register(session.descriptor) { session }
            let controller = VisualizationController(source: channel, registry: registry)
            controller.select(id: "test"); controller.resume(); controller.pause()
            let stopped = !session.active && controller.tick(deltaTime: 1) == nil
            channel.publish(audio: sample(onset: true, flux: 1), melody: nil, sessionID: id)
            let viewport = VisualizationViewport(width: 800, height: 520, scale: 2)
            controller.resize(to: viewport); controller.resume(); controller.tick(deltaTime: 0.01)
            return stopped && session.active && session.viewport == viewport && session.inputs.last?.onsets.isEmpty == true &&
                session.inputs.last?.spectralFluxPeak == 0 && channel.snapshot?.sessionID == id
        }
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        try JSONSerialization.data(withJSONObject: ["passed": checks.count - failures, "failed": failures, "checks": checks],
            options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "docs/validation/contract-tests.json"))
        if failures > 0 { exit(1) }
    }
}
