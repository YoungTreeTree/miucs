import AppKit
import Combine
import CoreAudio
import CoreMedia
import ScreenCaptureKit

@MainActor
protocol AudioCaptureSession: AnyObject {
    func start() async throws
    func stop() async
}

typealias AudioCaptureFactory = @MainActor (
    Bool, @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void,
    @escaping @Sendable (Error) -> Void
) async throws -> any AudioCaptureSession

struct AudioRecoveryTiming {
    var retryDelays = [1.0, 2, 4, 8, 16, 30]
    var restartDebounce = 0.7
    var watchdogInterval = 2.0
    var noDataTimeout = 12.0
    var stableReset = 20.0
    var permissionPoll = 5.0
}

enum AudioCaptureLifecycleEvent {
    case sleep, wake, screensSleep, screensWake, configurationChanged
}

/// Owns one capture generation. Old callbacks and cancelled attempts cannot revive it.
@MainActor
final class AudioEngine: NSObject, ObservableObject {
    let channel: FeatureChannel
    var features: AudioFeatures? { channel.snapshot?.audio }
    var melody: MelodyFrame? { channel.snapshot?.melody }
    @Published private(set) var status = "正在连接系统音频…"
    @Published private(set) var isRunning = false

    private let factory: AudioCaptureFactory
    private let timing: AudioRecoveryTiming
    private let now: @Sendable () -> Double
    private let audioExpected: @MainActor () -> Bool
    private let permissionGranted: @MainActor () -> Bool
    private let monitorsSystem: Bool
    private var session: (any AudioCaptureSession)?
    private var connecting: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private var outputObserver: AudioOutputObserver?
    private var generation = UUID()
    private var wanted = false
    private var isStarting = false
    private var systemSleeping = false
    private var screensSleeping = false
    private var waitingForPermission = false
    private var excludesExistingApplications = false
    private var failures = 0
    private var connectedAt = 0.0
    private var expectedAudioSince: Double?
    private var suspended: Bool { systemSleeping || screensSleeping }

    init(factory: AudioCaptureFactory? = nil, timing: AudioRecoveryTiming = AudioRecoveryTiming(),
         monitorsSystem: Bool = true,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         audioExpected: @escaping @MainActor () -> Bool = { AudioOutputObserver.isOutputActive() },
         permissionGranted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.channel = FeatureChannel(now: now)
        self.factory = factory ?? { try await ScreenAudioCapture.make(excludingExistingApplications: $0, onFrame: $1, onFailure: $2) }
        self.timing = timing; self.monitorsSystem = monitorsSystem
        self.now = now; self.audioExpected = audioExpected; self.permissionGranted = permissionGranted
        super.init()
    }

    func start(excludingExistingApplications: Bool = false) async {
        guard !wanted else { return }
        wanted = true; excludesExistingApplications = excludingExistingApplications
        installObservers()
        await connect()
    }

    func reconnect() async {
        wanted = true; failures = 0; waitingForPermission = false
        installObservers()
        invalidateCapture()
        await connect()
    }

    func stop() {
        wanted = false
        invalidateCapture()
        observers.removeAll(); outputObserver = nil
        failures = 0; waitingForPermission = false
        systemSleeping = false; screensSleeping = false
        setStatus(.stopped, "已暂停")
    }

    func handleLifecycle(_ event: AudioCaptureLifecycleEvent) {
        guard wanted else { return }
        let wasSuspended = suspended
        switch event {
        case .sleep: systemSleeping = true
        case .screensSleep: screensSleeping = true
        case .wake: systemSleeping = false; screensSleeping = false
        case .screensWake: screensSleeping = false
        case .configurationChanged: break
        }
        if suspended {
            invalidateCapture()
            setStatus(.suspended, "等待系统唤醒…")
        } else if wasSuspended || event == .configurationChanged {
            failures = 0
            recover("系统环境恢复", delay: timing.restartDebounce)
        }
    }

    private func connect() async {
        guard wanted, !suspended, !isStarting, session == nil else { return }
        let token = UUID(); generation = token; isStarting = true
        channel.reset(sessionID: token, state: .connecting)
        status = "正在连接系统音频…"
        let task = Task { [weak self] in
            guard let self else { return }
            await self.openCapture(token)
        }
        connecting = task
        await task.value
    }

    private func openCapture(_ token: UUID) async {
        var candidate: (any AudioCaptureSession)?
        do {
            await stopping?.value
            guard isCurrent(token) else { return }
            let channel = self.channel
            let capture = try await factory(excludesExistingApplications, { frame, melody in
                channel.publish(audio: frame, melody: melody, sessionID: token)
            }, { [weak self] error in
                Task { @MainActor in self?.captureFailed(error, token: token) }
            })
            candidate = capture
            guard isCurrent(token) else { await capture.stop(); return }
            session = capture
            try await capture.start()
            guard isCurrent(token) else { await capture.stop(); return }
            isStarting = false; connecting = nil; isRunning = true
            waitingForPermission = false
            connectedAt = now(); expectedAudioSince = nil
            setStatus(.running, "正在听系统声音")
            startWatchdog(token)
            Self.trace("capture started")
        } catch {
            guard isCurrent(token) else { await candidate?.stop(); return }
            captureFailed(error, token: token)
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { wanted && !suspended && generation == token }

    private func setStatus(_ state: AudioSourceState, _ message: String) {
        status = message; channel.setState(state)
    }

    private func resetBackoffIfHealthy() {
        if let first = channel.health.first, now() - first >= timing.stableReset { failures = 0 }
    }

    private func captureFailed(_ error: Error, token: UUID) {
        guard isCurrent(token) else { return }
        resetBackoffIfHealthy()
        Self.trace("capture interrupted: \(error)")
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userStopped.rawValue {
            stop() // Respect an explicit stop from macOS's capture controls.
            setStatus(.userStopped, "系统已停止音频捕获 · 可从菜单栏重新连接")
        } else if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
            waitingForPermission = true
            recover("等待音频捕获授权", delay: timing.permissionPoll)
        } else {
            recover("音频中断")
        }
    }

    private func recover(_ reason: String, delay: Double? = nil) {
        guard wanted else { return }
        invalidateCapture()
        guard !suspended else { setStatus(.suspended, "等待系统唤醒…"); return }
        let wait = delay ?? timing.retryDelays[min(failures, timing.retryDelays.count - 1)]
        if delay == nil { failures += 1 }
        setStatus(waitingForPermission ? .permissionRequired : .recovering,
                  waitingForPermission ? "等待音频捕获授权…" : "\(reason) · 正在自动重连…")
        scheduleRetry(after: wait)
    }

    private func scheduleRetry(after delay: Double) {
        retry?.cancel()
        let token = generation
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isCurrent(token) else { return }
            self.retry = nil
            if self.waitingForPermission && !self.permissionGranted() {
                // Read-only preflight: do not repeatedly invoke a permission prompt.
                self.scheduleRetry(after: self.timing.permissionPoll)
                return
            }
            await self.connect()
        }
    }

    private func invalidateCapture() {
        generation = UUID()
        connecting?.cancel(); connecting = nil
        retry?.cancel(); retry = nil
        watchdog?.cancel(); watchdog = nil
        let previousStop = stopping, old = session
        session = nil; isStarting = false; isRunning = false
        if let old {
            stopping = Task { await previousStop?.value; await old.stop() }
        }
        channel.reset(sessionID: generation, state: suspended ? .suspended : .stopped)
        expectedAudioSince = nil
    }

    private func startWatchdog(_ token: UUID) {
        watchdog?.cancel()
        let interval = timing.watchdogInterval
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.isCurrent(token), self.isRunning else { return }
                self.resetBackoffIfHealthy()
                if !self.audioExpected() {
                    self.expectedAudioSince = nil // An idle output device may deliver no PCM.
                    continue
                }
                let time = self.now()
                if self.expectedAudioSince == nil { self.expectedAudioSince = time }
                let reference = max(self.channel.health.last ?? self.connectedAt, self.expectedAudioSince ?? time)
                if time - reference >= self.timing.noDataTimeout {
                    Self.trace("capture stalled while output device active")
                    self.recover("音频数据中断")
                    return
                }
            }
        }
    }

    private func installObservers() {
        guard monitorsSystem, observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.willSleepNotification, AudioCaptureLifecycleEvent.sleep),
                              (NSWorkspace.didWakeNotification, .wake),
                              (NSWorkspace.screensDidSleepNotification, .screensSleep),
                              (NSWorkspace.screensDidWakeNotification, .screensWake),
                              (NSWorkspace.sessionDidBecomeActiveNotification, .configurationChanged)] {
            workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.handleLifecycle(event)
            }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.handleLifecycle(.configurationChanged)
            }.store(in: &observers)
        outputObserver = AudioOutputObserver { [weak self] in
            Task { @MainActor in self?.handleLifecycle(.configurationChanged) }
        }
    }

    nonisolated static func trace(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/miucs.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
            } else { try? data.write(to: url) }
        }
    }
}

/// ScreenCaptureKit's actual transport, isolated from recovery scheduling for testing.
@MainActor
private final class ScreenAudioCapture: NSObject, AudioCaptureSession, SCStreamDelegate {
    private var stream: SCStream!
    private var output: StreamOutput!
    private var hasStarted = false
    private var stopRequested = false
    private let onFailure: @Sendable (Error) -> Void

    private init(onFailure: @escaping @Sendable (Error) -> Void) { self.onFailure = onFailure }

    static func make(excludingExistingApplications: Bool,
                     onFrame: @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void,
                     onFailure: @escaping @Sendable (Error) -> Void) async throws -> ScreenAudioCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: !excludingExistingApplications)
        guard let display = content.displays.first else {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue)
        }
        let capture = ScreenAudioCapture(onFailure: onFailure)
        let filter = excludingExistingApplications
            ? SCContentFilter(display: display, excludingApplications: content.applications, exceptingWindows: [])
            : SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false; config.capturesAudio = true
        config.sampleRate = 48_000; config.channelCount = 2; config.excludesCurrentProcessAudio = true
        capture.output = try StreamOutput(onFrame: onFrame, onFailure: onFailure)
        capture.stream = SCStream(filter: filter, configuration: config, delegate: capture)
        try capture.stream.addStreamOutput(capture.output, type: .audio, sampleHandlerQueue: capture.output.queue)
        return capture
    }

    func start() async throws {
        try await stream.startCapture()
        hasStarted = true
        if stopRequested { await stop() }
    }

    func stop() async {
        stopRequested = true
        guard hasStarted else { return }
        hasStarted = false
        try? await stream.stopCapture()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure(error) }
}

/// Only observes the output route. Never changes the user's device or volume.
private final class AudioOutputObserver {
    private let listener: AudioObjectPropertyListenerBlock
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
    init(onChange: @escaping @Sendable () -> Void) {
        listener = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
    deinit { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) }

    static func isOutputActive() -> Bool {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        property.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// Each capture owns immutable callbacks and a fresh analyzer, used only on its audio queue.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "miucs.audio", qos: .userInteractive)
    private let onFrame: @Sendable (AudioFeatures, MelodyFrame?) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var consecutiveFailures = 0
    private var reportedFailure = false
    private let analysis: AudioAnalysisPipeline
    private var didLogBuffer = false
    private var didLogError = false

    init(onFrame: @escaping @Sendable (AudioFeatures, MelodyFrame?) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.onFrame = onFrame; self.onFailure = onFailure
        analysis = try AudioAnalysisPipeline()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        do {
            let block = try AudioPCMDecoder.decode(sampleBuffer)
            for frame in try analysis.process(block) {
                onFrame(frame.audio, frame.melody)
            }
            consecutiveFailures = 0
            if !didLogBuffer {
                didLogBuffer = true
                AudioEngine.trace(
                    "frames=\(block.channels[0].count) ch=\(block.channels.count) " +
                    "interleaved=\(block.isInterleaved) rate=\(Int(block.sampleRate))"
                )
            }
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 8 && !reportedFailure {
                reportedFailure = true; onFailure(error)
            }
            if !didLogError {
                didLogError = true
                AudioEngine.trace("analysis failed: \(error)")
            }
        }
    }
}
