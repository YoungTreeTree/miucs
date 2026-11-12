import Foundation
import Combine
import OSLog

/// Native-only pet lifecycle. It never creates a desktop window, render timer or plugin worker.
@MainActor
public final class NativePetSession: ObservableObject {
    @Published public private(set) var status = "未启用"
    @Published public private(set) var active = false
    private struct Configuration {
        let skin: PetSkin
        let audio: any AudioFeatureSource
        let keyboard: any KeyboardFeatureSource
        let transport: any NativePetTransport
    }
    private struct Identity {
        let length: Int
        let crc: UInt32
        var payload: Data {
            var bytes = Data()
            for value in [UInt32(length), crc] {
                withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
            }
            return bytes
        }
    }
    private var desired: Configuration?
    private var revision = 0
    private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.miucs.core", category: "native-pet")

    public init() {}
    deinit { task?.cancel() }

    public func start(skin: PetSkin, audio: any AudioFeatureSource, keyboard: any KeyboardFeatureSource,
                      transport: any NativePetTransport) {
        desired = Configuration(skin: skin, audio: audio, keyboard: keyboard, transport: transport)
        revision &+= 1
        task?.cancel()
        if task == nil { launch() }
    }

    public func stop() {
        desired = nil
        revision &+= 1
        task?.cancel()
        active = false
        status = "未启用"
    }

    /// Waits until in-flight work has relinquished the channel; useful for host shutdown/tests.
    public func waitUntilStopped() async { await task?.value }

    private func launch() {
        guard let configuration = desired, task == nil else { return }
        let token = revision
        task = Task { [weak self] in
            var identity: Identity?
            while !Task.isCancelled, token == self?.revision {
                do {
                    self?.active = false
                    self?.status = "正在连接桌宠…"
                    let card = try await configuration.transport.connect()
                    try Task.checkCancellation()
                    guard let capability = card.pet, HardwarePetPack.supports(configuration.skin.id, on: capability) else {
                        throw HardwareSerialError.message("当前固件不支持这个皮肤")
                    }
                    self?.status = "正在同步皮肤 · \(configuration.skin.name)"
                    try await Self.synchronize(configuration, card: card, identity: &identity) { [weak self] percent in
                        guard self?.revision == token else { return }
                        self?.status = "正在同步皮肤 · \(configuration.skin.name) · \(percent)%"
                    }
                    try Task.checkCancellation()
                    self?.active = true
                    self?.status = "板端绘制 · \(configuration.skin.name)"
                    try await Self.stream(configuration, card: card)
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    self?.active = false
                    self?.status = error.localizedDescription
                    Self.log.info("Pet connection will retry: \(error.localizedDescription, privacy: .public)")
                    await configuration.transport.close(clear: false)
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            // On a skin switch preserve the last board frame until its replacement is ready.
            // Removing/disabling the component clears explicitly after cancellation has unwound.
            let clear = self?.desired == nil
            await Task.detached { await configuration.transport.close(clear: clear) }.value
            guard let self else { return }
            self.active = false
            self.task = nil
            if self.desired != nil { self.launch() }
        }
    }

    private static func synchronize(_ configuration: Configuration, card: DeskIsleCard, identity: inout Identity?,
                                    progress: (Int) -> Void) async throws {
        let capability = card.pet!
        if let identity, try await resume(identity, card: card, transport: configuration.transport) { return }
        let skin = configuration.skin
        let pack = try await Task.detached(priority: .utility) {
            try HardwarePetPack.make(directory: skin.directory, limit: capability.maxPack)
        }.value
        try Task.checkCancellation()
        let next = Identity(length: pack.count, crc: HardwareFrame.crc32(pack))
        if identity == nil, try await resume(next, card: card, transport: configuration.transport) {
            identity = next
            return
        }
        try await configuration.transport.send(.begin, payload: next.payload, card: card)
        // maxChunk is a limit, not a required size. Smaller commands leave room
        // for other components on a shared UART and bound cancellation latency.
        let chunkSize = min(capability.maxChunk, 32 * 1024)
        var lastPercent = -1
        for offset in stride(from: 0, to: pack.count, by: chunkSize) {
            try Task.checkCancellation()
            var chunk = Data()
            withUnsafeBytes(of: UInt32(offset).littleEndian) { chunk.append(contentsOf: $0) }
            let end = min(offset + chunkSize, pack.count)
            chunk.append(pack[offset..<end])
            do { try await configuration.transport.send(.chunk, payload: chunk, card: card) }
            catch HardwareSerialError.petRejected("1") {
                try await configuration.transport.send(.chunk, payload: chunk, card: card)
            }
            let percent = end * 100 / pack.count
            if percent != lastPercent { progress(percent); lastPercent = percent }
        }
        try Task.checkCancellation()
        try await configuration.transport.send(.commit, payload: Data(), card: card)
        identity = next
        log.info("Screen activated native Lua pet \(skin.id, privacy: .public) (\(pack.count) bytes)")
    }

    private static func resume(_ identity: Identity, card: DeskIsleCard, transport: any NativePetTransport) async throws -> Bool {
        guard card.pet!.version >= 3 else { return false }
        do {
            try await transport.send(.resume, payload: identity.payload, card: card)
            log.info("Screen resumed native Lua pet (\(identity.length) bytes)")
            return true
        } catch HardwareSerialError.petRejected("6") { return false }
    }

    private final class WakeState {
        var keyboard = true
        var audio = true
    }

    private static func stream(_ configuration: Configuration, card: DeskIsleCard) async throws {
        let audio = configuration.audio.subscribe()
        let keyboard = configuration.keyboard.subscribe()
        let state = WakeState()
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let keys = Task {
            for await _ in keyboard.eventSignals() {
                guard !Task.isCancelled else { return }
                state.keyboard = true; continuation.yield()
            }
        }
        let sound = Task {
            for await _ in audio.activitySignals() {
                guard !Task.isCancelled else { return }
                state.audio = true; continuation.yield()
            }
        }
        let keepalive = Task {
            while !Task.isCancelled {
                continuation.yield()
                do { try await Task.sleep(for: .seconds(card.keepaliveInterval)) } catch { return }
            }
        }
        var audioWake: Task<Void, Never>?
        defer {
            keys.cancel(); sound.cancel(); keepalive.cancel(); audioWake?.cancel()
            continuation.finish()
        }
        var lastSent = -Double.infinity
        for await _ in signals {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let interval = card.pet!.version == 1 || state.audio ? 1.0 / 30 : card.keepaliveInterval
            let delay = lastSent + interval - now
            if !state.keyboard, delay > 0 {
                if state.audio, audioWake == nil {
                    audioWake = Task {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        continuation.yield()
                    }
                }
                continue
            }
            audioWake?.cancel(); audioWake = nil
            state.keyboard = false; state.audio = false
            let payload = try PetInputSnapshot.encode(audio: audio.read(), keyboard: keyboard.read(), limit: card.pet!.maxInput)
            do { try await configuration.transport.send(.input, payload: payload, card: card) }
            catch HardwareSerialError.petRejected("1") { /* Next snapshot refreshes state after a corrupt packet. */ }
            lastSent = now
        }
        try Task.checkCancellation()
    }
}
