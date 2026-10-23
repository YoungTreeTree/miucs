import Foundation

@MainActor
final class StaffNoteSimulation: VisualizationSession {
    static let module = VisualizationDescriptor(id: "staff-note", name: "五线谱音符",
        layout: VisualizationLayout(width: 800, height: 160, minimumWidth: 600, maximumWidth: 1600))
    var descriptor: VisualizationDescriptor { Self.module }
    private(set) var scene = StaffNoteScene()
    private(set) var needsDisplay = true
    private var active = false
    private var sessionID: UUID?
    private var sequence: UInt64?
    private var lastMelodyTime: Double?
    private var lastAudioTime: Double?
    private var sampleRate: Double?
    private var channels: Int?
    private var onsetSequence: UInt64 = 0

    func activate(viewport: VisualizationViewport) {
        active = true; needsDisplay = true
        scene.resetInput(clearHistory: true)
        sequence = nil; lastMelodyTime = nil; lastAudioTime = nil
    }
    func resize(to viewport: VisualizationViewport) { needsDisplay = true }
    func deactivate() { active = false; scene.resetInput(clearHistory: true) }
    func dispose() { deactivate() }
    func update(input: FeatureInput, deltaTime: Double) {
        guard active else { return }
        let wasMoving = scene.needsMotionUpdates
        scene.elapse(seconds: deltaTime)
        var changed = false
        if sessionID != input.sessionID {
            scene.resetInput(clearHistory: true); sessionID = input.sessionID
            sequence = nil; lastMelodyTime = nil; lastAudioTime = nil
            sampleRate = nil; channels = nil; onsetSequence = 0; changed = true
        }
        if input.state == .running, let frame = input.frame, frame.sessionID == input.sessionID,
           let age = input.frameAge, age.isFinite, age >= 0, age < 0.4 {
            let formatChanged = sampleRate != frame.audio.sampleRate || channels != frame.audio.channelCount ||
                (lastAudioTime.map { frame.audio.time < $0 } ?? false)
            if formatChanged {
                scene.resetInput(clearHistory: true); lastMelodyTime = nil; sequence = nil
                // Events from the earlier format must not spill into the new scene.
                if sampleRate != nil { onsetSequence = frame.sequence }
                sampleRate = frame.audio.sampleRate; channels = frame.audio.channelCount; changed = true
            }
            scene.receive(audio: frame.audio, age: age)
            if sequence != frame.sequence {
                if let melody = frame.melody {
                    if lastMelodyTime.map({ melody.time < $0 }) == true {
                        scene.resetInput(clearHistory: true); scene.receive(audio: frame.audio, age: age)
                        lastMelodyTime = nil; onsetSequence = frame.sequence
                    }
                    if melody.time != lastMelodyTime {
                        let melodyAge = age + max(0, frame.audio.time - melody.time)
                        scene.receive(melody: melody, age: melodyAge); lastMelodyTime = melody.time
                    }
                } else { scene.receive(melody: nil) }
                lastAudioTime = frame.audio.time; sequence = frame.sequence; changed = true
            }
            let events = input.onsets.filter { $0.sequence > onsetSequence && $0.sequence <= frame.sequence }
            if let strength = events.map(\.strength).max() { scene.receiveOnset(strength: strength); changed = true }
            onsetSequence = max(onsetSequence, frame.sequence)
        } else {
            scene.receive(audio: nil)
        }
        scene.animate(seconds: min(deltaTime, 0.1))
        needsDisplay = changed || wasMoving || scene.needsMotionUpdates
    }
}
