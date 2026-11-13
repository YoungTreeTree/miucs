import Foundation

public enum AudioSourceState: String, Codable, Sendable {
    case stopped, connecting, running, recovering, suspended, permissionRequired, userStopped
}

/// Value contract v1. PCM window time and host-monotonic receipt time are distinct.
public struct AudioFeatureFrame: Codable, Sendable {
    public var version = 1
    public let sessionID: UUID
    public let sequence: UInt64
    public let receivedAt: Double
    public let audio: AudioFeatures
    public let melody: MelodyFrame?
}

public struct AudioOnsetEvent: Codable, Sendable {
    public let sequence: UInt64
    public let time: Double
    public let receivedAt: Double
    public let strength: Double
}

public struct FeatureInput: Codable, Sendable {
    public var version = 1
    public let sessionID: UUID
    public let state: AudioSourceState
    public let frame: AudioFeatureFrame?
    public let frameAge: Double?
    public let onsets: [AudioOnsetEvent]
    public let spectralFluxPeak: Double
    /// Missing in v1 recordings made before beat tracking was added.
    public var beats: [AudioBeatEvent]? = nil
}

public protocol AudioFeatureSource: Sendable {
    func subscribe() -> FeatureSubscription
}

/// A consumer owns its cursor; one consumer cannot drain another's events.
public final class FeatureSubscription: @unchecked Sendable {
    private let channel: FeatureChannel
    private let lock = NSLock()
    private var sessionID: UUID
    private var sequence: UInt64
    fileprivate init(channel: FeatureChannel, sessionID: UUID, sequence: UInt64) {
        self.channel = channel; self.sessionID = sessionID; self.sequence = sequence
    }
    public func read() -> FeatureInput {
        lock.lock(); defer { lock.unlock() }
        let input = channel.read(sessionID: sessionID, after: sequence)
        sessionID = input.sessionID
        sequence = input.frame?.sequence ?? 0
        return input
    }

    public func activitySignals() -> AsyncStream<Void> { channel.activitySignals() }
}

/// Short-lock UI handoff: one snapshot, 64 onsets, and a recent flux maximum deque.
/// Consumers can opt in to wakeups for active audio and capture state changes.
public final class FeatureChannel: AudioFeatureSource, @unchecked Sendable {
    public static let eventCapacity = 64
    public static let eventLifetime = 0.250
    private struct FluxSample { let sequence: UInt64; let receivedAt: Double; let value: Double }
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var sessionID = UUID()
    private var state = AudioSourceState.stopped
    private var sequence: UInt64 = 0
    private var latestFrame: AudioFeatureFrame?
    private var onsets = [AudioOnsetEvent]()
    private var beats = [AudioBeatEvent]()
    private var lastBeatTime: Double?
    private var flux = [FluxSample]()
    private var firstFrameAt: Double?
    private var lastFrameAt: Double?
    private var recordFrames = false
    private var recorded = [AudioFeatureFrame]()
    private var activityObservers = [UUID: AsyncStream<Void>.Continuation]()

    public init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    public func reset(sessionID: UUID, state: AudioSourceState) {
        lock.lock()
        self.sessionID = sessionID; self.state = state; sequence = 0
        latestFrame = nil; onsets.removeAll(keepingCapacity: true); flux.removeAll(keepingCapacity: true)
        firstFrameAt = nil; lastFrameAt = nil
        beats.removeAll(keepingCapacity: true); lastBeatTime = nil
        unlockAndSignalActivity()
    }

    public func setState(_ state: AudioSourceState) {
        lock.lock()
        guard self.state != state else { lock.unlock(); return }
        self.state = state
        if state != .running { beats.removeAll(keepingCapacity: true) }
        unlockAndSignalActivity()
    }

    @discardableResult
    public func publish(audio: AudioFeatures, melody: MelodyFrame?, sessionID: UUID) -> Bool {
        let time = now()
        lock.lock()
        guard sessionID == self.sessionID, state == .running else { lock.unlock(); return false }
        let signalActivity = !audio.isSilent || latestFrame?.audio.isSilent != true
        if let previous = latestFrame?.audio,
           previous.sampleRate != audio.sampleRate || previous.channelCount != audio.channelCount || audio.time < previous.time {
            beats.removeAll(keepingCapacity: true); lastBeatTime = nil
        }
        sequence += 1
        let frame = AudioFeatureFrame(sessionID: sessionID, sequence: sequence,
                                      receivedAt: time, audio: audio, melody: melody)
        latestFrame = frame
        firstFrameAt = firstFrameAt ?? time; lastFrameAt = time
        let cutoff = time - Self.eventLifetime
        onsets.removeAll { $0.receivedAt < cutoff }; flux.removeAll { $0.receivedAt < cutoff }
        beats.removeAll { $0.receivedAt < cutoff }
        if audio.isSilent { beats.removeAll(keepingCapacity: true) }
        if !audio.isSilent {
            if let beat = audio.beat, let pulse = beat.beatTime, let bpm = beat.bpm,
               pulse.isFinite, pulse >= 0, pulse <= audio.time, audio.time - pulse <= 0.10,
               lastBeatTime.map({ pulse > $0 }) ?? true,
               bpm.isFinite, (BeatTracker.minimumBPM...BeatTracker.maximumBPM).contains(bpm),
               beat.confidence.isFinite, (BeatTracker.minimumConfidence...1).contains(beat.confidence),
               beat.strength.isFinite, (0...1).contains(beat.strength) {
                beats.append(AudioBeatEvent(sequence: sequence, time: pulse,
                    receivedAt: time - (audio.time - pulse), strength: beat.strength, bpm: bpm, confidence: beat.confidence))
                lastBeatTime = pulse
                if beats.count > Self.eventCapacity { beats.removeFirst(beats.count - Self.eventCapacity) }
            }
            if audio.isOnset {
                onsets.append(AudioOnsetEvent(sequence: sequence, time: audio.time,
                    receivedAt: time, strength: audio.spectralFlux))
                if onsets.count > Self.eventCapacity { onsets.removeFirst(onsets.count - Self.eventCapacity) }
            }
            if audio.spectralFlux.isFinite, audio.spectralFlux > 0 {
                // A later, stronger sample dominates earlier samples for every reader.
                // Unlike truncating a sample ring, this preserves a short peak even
                // when a burst contains more than 64 frames within the expiry window.
                while let last = flux.last, last.value <= audio.spectralFlux { flux.removeLast() }
                flux.append(FluxSample(sequence: sequence, receivedAt: time, value: audio.spectralFlux))
            }
        }
        // Explicit diagnostic tap, bounded to ~3 minutes at 48 kHz. Disabled in normal use.
        if recordFrames {
            recorded.append(frame)
            if recorded.count > 10_000 { recorded.removeFirst(recorded.count - 10_000) }
        }
        if signalActivity { unlockAndSignalActivity() } else { lock.unlock() }
        return true
    }

    private func unlockAndSignalActivity() {
        let observers = activityObservers.values
        lock.unlock()
        for observer in observers { observer.yield() }
    }

    public func subscribe() -> FeatureSubscription {
        lock.lock(); defer { lock.unlock() }
        return FeatureSubscription(channel: self, sessionID: sessionID, sequence: sequence)
    }

    fileprivate func activitySignals() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.removeActivityObserver(id) }
        lock.lock()
        activityObservers[id] = continuation
        lock.unlock()
        continuation.yield()
        return stream
    }

    private func removeActivityObserver(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        activityObservers.removeValue(forKey: id)
    }

    fileprivate func read(sessionID: UUID, after cursor: UInt64) -> FeatureInput {
        let time = now()
        let cutoff = time - Self.eventLifetime
        lock.lock(); defer { lock.unlock() }
        onsets.removeAll { $0.receivedAt < cutoff }; flux.removeAll { $0.receivedAt < cutoff }
        beats.removeAll { $0.receivedAt < cutoff }
        let after = sessionID == self.sessionID ? cursor : 0
        let events = onsets.filter { $0.sequence > after && $0.receivedAt >= cutoff }
        let peak = flux.lazy.filter { $0.sequence > after && $0.receivedAt >= cutoff }.map(\.value).max() ?? 0
        return FeatureInput(sessionID: self.sessionID, state: state, frame: latestFrame,
                            frameAge: latestFrame.map { max(0, time - $0.receivedAt) },
                            onsets: events, spectralFluxPeak: peak, beats: beats.filter { $0.sequence > after })
    }

    public var snapshot: AudioFeatureFrame? {
        lock.lock(); defer { lock.unlock() }; return latestFrame
    }
    public var health: (first: Double?, last: Double?) {
        lock.lock(); defer { lock.unlock() }; return (firstFrameAt, lastFrameAt)
    }
    public var currentState: AudioSourceState {
        lock.lock(); defer { lock.unlock() }; return state
    }

    public func startRecording() {
        lock.lock(); defer { lock.unlock() }; recorded.removeAll(); recordFrames = true
    }
    public func stopRecording() -> [AudioFeatureFrame] {
        lock.lock(); defer { lock.unlock() }; recordFrames = false
        defer { recorded.removeAll() }; return recorded
    }
    public var recordedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }; return recorded.count
    }
}
