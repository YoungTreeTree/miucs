import AppKit
import Carbon
import Combine
import CoreGraphics

struct KeyboardEnvironment: Sendable {
    var permissionGranted: Bool
    var secureInput: Bool
    @MainActor static func current() async -> Self {
        let permission = await Task.detached(priority: .utility) { CGPreflightListenEventAccess() }.value
        // Carbon documents this query as not thread safe; serialize it on the main actor.
        return Self(permissionGranted: permission, secureInput: IsSecureEventInputEnabled())
    }
}

enum KeyboardLifecycleEvent { case sleep, wake, sessionInactive, sessionActive }
typealias KeyboardCaptureFactory = @Sendable (
    @escaping @Sendable (KeyboardRawEvent) -> Void, @escaping @Sendable () -> Void
) -> any KeyboardCaptureSession

/// Keyboard lifetime is independent of audio capture and of the currently visible module.
@MainActor
final class KeyboardEngine: ObservableObject {
    let channel: KeyboardChannel
    @Published private(set) var state = KeyboardSourceState.stopped
    private let factory: KeyboardCaptureFactory
    private let environment: @MainActor () async -> KeyboardEnvironment
    private let requestPermission: @MainActor () -> Bool
    private let now: @Sendable () -> Double
    private let pollInterval: Double
    private let monitorsSystem: Bool
    private var capture: (any KeyboardCaptureSession)?
    private var polling: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private var generation = UUID()
    private var lifecycle = UUID()
    private var wanted = false
    private var checking: UUID?
    private var pendingPermissionRequest = false
    private var sleeping = false
    private var inactive = false
    private var failures = 0
    private var retryAt = 0.0

    init(factory: @escaping KeyboardCaptureFactory = { KeyboardEventTap(onEvent: $0, onInterruption: $1) },
         environment: @escaping @MainActor () async -> KeyboardEnvironment = { await KeyboardEnvironment.current() },
         requestPermission: @escaping @MainActor () -> Bool = { CGRequestListenEventAccess() },
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         pollInterval: Double = 1, monitorsSystem: Bool = true) {
        self.channel = KeyboardChannel(now: now); self.factory = factory
        self.environment = environment; self.requestPermission = requestPermission; self.now = now
        self.pollInterval = pollInterval; self.monitorsSystem = monitorsSystem
    }

    deinit { polling?.cancel(); capture?.stop() }

    func start(requestAccess: Bool = false) async {
        if !wanted {
            wanted = true; lifecycle = UUID(); installObservers()
            polling = Task { [weak self, pollInterval] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(pollInterval)) } catch { return }
                    guard let self else { return }
                    await self.refresh()
                }
            }
        }
        await refresh(requestAccess: requestAccess)
    }

    func stop() {
        wanted = false; lifecycle = UUID()
        checking = nil; pendingPermissionRequest = false
        polling?.cancel(); polling = nil; observers.removeAll()
        sleeping = false; inactive = false; failures = 0; retryAt = 0
        invalidate(to: .stopped)
    }

    func handleLifecycle(_ event: KeyboardLifecycleEvent) {
        guard wanted else { return }
        switch event {
        case .sleep: sleeping = true
        case .wake: sleeping = false
        case .sessionInactive: inactive = true
        case .sessionActive: inactive = false
        }
        lifecycle = UUID(); failures = 0; retryAt = 0
        checking = nil
        invalidate(to: sleeping || inactive ? .suspended : .connecting)
        if !sleeping && !inactive { Task { [weak self] in await self?.refresh() } }
    }

    /// Used by the slow health poll and by an explicit permission action; never by a display frame.
    func refresh(requestAccess: Bool = false) async {
        if requestAccess { pendingPermissionRequest = true }
        guard wanted, !sleeping, !inactive, checking == nil else { return }
        let checkID = UUID(); checking = checkID
        defer {
            if checking == checkID {
                checking = nil
                if pendingPermissionRequest && wanted { Task { [weak self] in await self?.refresh() } }
            }
        }
        let lifetime = lifecycle
        var current = await environment()
        guard wanted, lifetime == lifecycle else { return }
        let request = pendingPermissionRequest; pendingPermissionRequest = false
        if request && !current.permissionGranted {
            _ = requestPermission()
            current = await environment()
            guard wanted, lifetime == lifecycle else { return }
        }
        guard current.permissionGranted else {
            invalidate(to: .permissionRequired); failures = 0; retryAt = 0; return
        }
        guard !current.secureInput else {
            invalidate(to: .secureInput); failures = 0; retryAt = 0; return
        }
        guard capture == nil, now() >= retryAt else { return }
        let token = UUID(); generation = token
        channel.reset(sessionID: token, state: .connecting); state = .connecting
        let channel = self.channel
        let candidate = factory({ event in
            channel.publish(event, sessionID: token)
        }, { [weak self] in
            Task { @MainActor in self?.interrupted(token: token) }
        })
        capture = candidate
        do {
            try await candidate.start()
            guard wanted, lifetime == lifecycle, generation == token else { candidate.stop(); return }
            channel.setRunning(sessionID: token); state = .running
            failures = 0; retryAt = 0
        } catch {
            candidate.stop()
            guard wanted, lifetime == lifecycle, generation == token else { return }
            interrupted(token: token)
        }
    }

    private func interrupted(token: UUID) {
        guard wanted, generation == token else { return }
        invalidate(to: .recovering)
        retryAt = now() + min(30, pow(2, Double(min(failures, 5))))
        failures += 1
    }

    private func invalidate(to next: KeyboardSourceState) {
        guard state != next || capture != nil else { return }
        // Reject old callbacks before asking the run loop to stop.
        generation = UUID()
        channel.reset(sessionID: generation, state: next)
        capture?.stop(); capture = nil
        state = next
    }

    private func installObservers() {
        guard monitorsSystem, observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, KeyboardLifecycleEvent)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive)]
        for (name, event) in events {
            center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.handleLifecycle(event) }
            }.store(in: &observers)
        }
    }
}
