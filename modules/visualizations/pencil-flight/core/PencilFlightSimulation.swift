import Foundation

/// Feature-to-motion interpretation belongs to this visualization, not to audio analysis.
@MainActor
final class PencilFlightSimulation: VisualizationSession {
    static let module = VisualizationDescriptor(id: "pencil-flight", name: "铅笔飞鸟")
    var descriptor: VisualizationDescriptor { Self.module }
    private(set) var world = SoundFlightWorld()
    private(set) var needsDisplay = true
    private var sessionID: UUID?
    private var sequence: UInt64 = 0
    private var sampleRate: Double?
    private var channelCount: Int?
    private var active = false
    init(world: SoundFlightWorld = SoundFlightWorld()) { self.world = world }
    func activate(viewport: VisualizationViewport) { active = true; needsDisplay = true }
    func resize(to viewport: VisualizationViewport) { needsDisplay = true }
    func deactivate() { active = false }
    func dispose() { deactivate() }
    func update(input: FeatureInput, deltaTime: Double) {
        guard active else { return }
        let wasMoving = world.activity > 0 || !world.particles.isEmpty || world.flap > 0.001 || world.needsMotionUpdates
        if input.sessionID != sessionID {
            world.receive(audio: nil); sessionID = input.sessionID; sequence = 0
            sampleRate = nil; channelCount = nil
        }
        if input.state == .running, let frame = input.frame, let age = input.frameAge, age < 0.4 {
            if frame.sequence != sequence {
                if sampleRate != frame.audio.sampleRate || channelCount != frame.audio.channelCount {
                    world.receive(audio: nil)
                    sampleRate = frame.audio.sampleRate; channelCount = frame.audio.channelCount
                }
                var audio = frame.audio
                // The channel supplies interval events/peaks separately from latest state.
                audio.isOnset = false; audio.spectralFlux = 0
                world.receive(audio: audio, age: age); world.receive(melody: frame.melody)
                sequence = frame.sequence
            }
            world.receive(onset: !input.onsets.isEmpty, spectralFluxPeak: input.spectralFluxPeak)
        } else { world.receive(audio: nil) }
        world.advance(seconds: deltaTime)
        needsDisplay = wasMoving || world.activity > 0 || !world.particles.isEmpty || world.needsMotionUpdates
    }
}
