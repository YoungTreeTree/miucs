#if canImport(MiucsCore)
import MiucsCore
#endif
import AppKit
import Combine
import OSLog

@MainActor
final class HardwareDisplay: ObservableObject {
    static let shared = HardwareDisplay()
    @Published private(set) var enabled: Bool
    @Published private(set) var orientation: HardwareOrientation
    @Published private(set) var status = "未启用"
    @Published private(set) var detail = ""
    @Published private(set) var screen: HardwareScreen?
    var connected: Bool { screen != nil }
    private let preferences: UserDefaults
    private let serial = HardwareSerial()
    private var started = false
    private var timer: Timer?
    private var wakeDeadline = Double.infinity
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var selectedID = ""
    private var package: PluginPackage?
    private var nextAttempt = 0.0
    private var lastCaptureAt = 0.0
    private var lastCardPixels: Data?
    private var lastCardMessageAt = 0.0
    private var sequence: UInt32 = 0
    private var measuredAt = 0.0
    private var measuredFrames = 0
    private var observers = [NSObjectProtocol]()
    private var suspended = false
    private enum NativePetState { case pending, active, fallback }
    private struct NativePetIdentity: Equatable, Sendable {
        let size: Int
        let crc: UInt32

        var payload: Data {
            var data = Data()
            withUnsafeBytes(of: UInt32(size).littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: crc.littleEndian) { data.append(contentsOf: $0) }
            return data
        }
    }
    private var nativePet = NativePetState.pending
    private var nativePetIdentity: NativePetIdentity?
    private var skinRevision = 0
    private var nativeAudio: FeatureSubscription?
    private var nativeKeyboard: KeyboardSubscription?
    private var nativeAudioTask: Task<Void, Never>?
    private var nativeKeyboardTask: Task<Void, Never>?
    private var nativeAudioPending = false
    private var nativeKeyboardPending = false
    private var lastNativeInputAt = -Double.infinity
    private static let nativeInputInterval = 1.0 / 30
    private let petLog = Logger(subsystem: "com.miucs.hardware", category: "native-pet")

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.bool(forKey: "MiucsHardware.enabled")
        orientation = HardwareOrientation(rawValue: preferences.object(forKey: "MiucsHardware.orientation") as? Int ?? 1) ?? .landscape
    }
    func start() {
        guard !started else { return }
        started = true
        status = enabled ? "等待连接屏幕…" : "未启用"
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.suspended = name == NSWorkspace.willSleepNotification
                    self.resetConnection()
                }
            })
        }
        tick()
    }
    func setEnabled(_ value: Bool) {
        enabled = value; preferences.set(value, forKey: "MiucsHardware.enabled")
        resetConnection(clearPet: !value)
    }
    func setOrientation(_ value: HardwareOrientation) {
        orientation = value; preferences.set(value.rawValue, forKey: "MiucsHardware.orientation")
    }
    func selectSkin(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        releasePackage()
        reloadSkin()
    }
    func reloadSkin() {
        nativePetIdentity = nil
        invalidateSkin()
        tick()
    }
    private func invalidateSkin() {
        skinRevision &+= 1
        nativePet = .pending
        stopNativeInput()
        lastNativeInputAt = -.infinity
        lastCardPixels = nil
    }
    private func stopNativeInput() {
        nativeAudioTask?.cancel()
        nativeAudioTask = nil
        nativeKeyboardTask?.cancel()
        nativeKeyboardTask = nil
        nativeAudioPending = false
        nativeKeyboardPending = false
        nativeAudio = nil
        nativeKeyboard = nil
    }
    func reconnect() { resetConnection() }
    func stop() {
        started = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        resetConnection()
    }
    private func resetConnection(clearPet: Bool = false) {
        cancelWake()
        generation = UUID(); job?.cancel(); job = nil
        let clearedScreen = clearPet ? screen : nil
        if clearedScreen != nil { sequence &+= 1 }
        let closeSequence = sequence
        screen = nil; detail = ""; nextAttempt = 0
        invalidateSkin()
        measuredAt = 0; measuredFrames = 0
        releasePackage()
        // Keep the close operation in the job slot so a newly opened connection cannot
        // race an asynchronous close left over from a previous generation.
        let token = generation
        job = Task {
            guard generation == token else { return }
            await serial.close(clearing: clearedScreen, sequence: closeSequence)
            finishJob(token)
        }
        status = !enabled ? "未启用" : suspended ? "电脑休眠，等待恢复" : "等待连接屏幕…"
    }

    private func cancelWake() {
        timer?.invalidate()
        timer = nil
        wakeDeadline = .infinity
    }

    private func wake(at deadline: Double, now: Double) {
        guard deadline < wakeDeadline else { return }
        cancelWake()
        wakeDeadline = deadline
        let interval = max(0.001, deadline - now)
        let wake = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wakeDeadline == deadline else { return }
                self.cancelWake()
                self.tick()
            }
        }
        if interval > 0.1 { wake.tolerance = min(0.02, interval / 10) }
        timer = wake
        RunLoop.main.add(wake, forMode: .common)
    }

    private func finishJob(_ token: UUID) {
        guard generation == token else { return }
        job = nil
        tick()
    }
    private func releasePackage() {
        guard let package else { return }
        package.hardwareActive = false
        if package.activeID == nil { package.post("deactivate") }
        PluginHost.shared.releaseUnused(package)
        PluginHost.shared.updateSchedule()
        self.package = nil
    }
    private func acquirePackage() -> PluginPackage? {
        if let package { return package }
        guard let metadata = PluginHost.shared.metadata.first(where: { $0["id"] as? String == selectedID }),
              let layout = metadata["layout"] as? [String: Double], let w = layout["width"], let h = layout["height"] else { return nil }
        let package = PluginHost.shared.package(metadata)
        package.hardwareActive = true
        if package.activeID == nil { package.post("activate", ["id": selectedID, "width": w, "height": h, "scale": 1]) }
        PluginHost.shared.updateSchedule()
        self.package = package
        return package
    }
    private func tick() {
        guard started, enabled, !suspended, job == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let token = generation
        guard let screen else {
            guard now >= nextAttempt else { wake(at: nextAttempt, now: now); return }
            cancelWake()
            nextAttempt = now + 2
            let ports = HardwarePort.connected()
            guard let port = ports.first else {
                let waiting = "等待连接屏幕…"
                let hint = "请连接小屏。使用 CH343 烧录口时，请保持桌屿运行。"
                if status != waiting { status = waiting }
                if detail != hint { detail = hint }
                wake(at: nextAttempt, now: now)
                return
            }
            status = "正在连接屏幕…"
            job = Task {
                defer { finishJob(token) }
                do {
                    let screen = try await serial.connect(path: port.path, unixSocket: port.path == HardwarePort.deskIsleRelayPath)
                    guard generation == token else { return }
                    self.screen = screen
                    status = "已连接 · \(screen.card?.title ?? "Miucs 屏幕")"
                    detail = port.path == HardwarePort.deskIsleRelayPath ? "通过桌屿连接 CH343" : port.path
                    measuredAt = ProcessInfo.processInfo.systemUptime; measuredFrames = 0
                } catch {
                    guard generation == token else { return }
                    status = error.localizedDescription; nextAttempt = ProcessInfo.processInfo.systemUptime + 2
                }
            }
            return
        }
        if let card = screen.card, let capability = card.pet,
           HardwarePetPack.supports(selectedID, on: capability), nativePet != .fallback {
            tickNativePet(now: now, card: card, capability: capability, token: token)
            return
        }
        let captureAt = lastCaptureAt + 1.0 / 20
        guard now >= captureAt else { wake(at: captureAt, now: now); return }
        cancelWake()
        guard let package = acquirePackage(),
              let metadata = PluginHost.shared.metadata.first(where: { $0["id"] as? String == selectedID }),
              let layout = metadata["layout"] as? [String: Double], let width = layout["width"], let height = layout["height"] else {
            wake(at: now + 2, now: now)
            return
        }
        let orientation = orientation
        let scale = screen.fitScale(width: width, height: height, orientation: orientation)
        let w = max(1, Int(width * scale)), h = max(1, Int(height * scale))
        lastCaptureAt = now
        guard let pixels = package.pixels(width: w, height: h) else {
            wake(at: now + 1.0 / 20, now: now)
            return
        }
        let cardAge = now - lastCardMessageAt
        let idleCard: DeskIsleCard?
        if let card = screen.card, cardAge < card.leaseDuration, pixels == lastCardPixels {
            guard cardAge >= card.keepaliveInterval else {
                wake(at: now + 1.0 / 20, now: now)
                return
            }
            idleCard = card
        } else {
            idleCard = nil
        }
        sequence &+= 1
        let sequence = sequence
        job = Task {
            defer { finishJob(token) }
            do {
                let packet: Data?
                if let idleCard {
                    packet = HardwareFrame.keepalive(sequence: sequence, card: idleCard)
                } else {
                    packet = await Task.detached(priority: .userInitiated) {
                        HardwareFrame.packet(bgra: pixels, width: w, height: h, orientation: orientation,
                                             sequence: sequence, screen: screen)
                    }.value
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                guard let packet else { throw HardwareSerialError.message("当前皮肤无法编码为屏幕画面") }
                let sentAt = ProcessInfo.processInfo.systemUptime
                let decodeMS = try await serial.send(packet, sequence: sequence, screen: screen)
                guard generation == token else { return }
                let acceptedAt = ProcessInfo.processInfo.systemUptime
                if let card = screen.card {
                    let leaseExpired = acceptedAt - lastCardMessageAt >= card.leaseDuration
                    lastCardMessageAt = sentAt
                    if idleCard != nil {
                        // If the board may have restored the wallpaper, refresh the JPEG next tick.
                        if leaseExpired { lastCardPixels = nil }
                        let idleDetail = "画面静止 · 连接保持中"
                        if detail != idleDetail { detail = idleDetail }
                        measuredAt = acceptedAt; measuredFrames = 0
                        return
                    }
                    lastCardPixels = pixels
                }
                let displaying = "正在显示 · \(screen.card?.title ?? orientation.title)"
                if status != displaying { status = displaying }
                measuredFrames += 1
                let elapsed = acceptedAt - measuredAt
                if elapsed >= 1 {
                    detail = String(format: "%.1f 帧/秒 · %.0f KB/帧 · 屏幕处理 %d ms", Double(measuredFrames) / elapsed, Double(packet.count) / 1024, decodeMS)
                    measuredAt = acceptedAt; measuredFrames = 0
                }
            } catch HardwareSerialError.cardChanged(let card) {
                guard generation == token else { return }
                updateCard(card)
            } catch {
                guard generation == token else { return }
                connectionLost(error)
            }
        }
    }

    private func updateCard(_ card: DeskIsleCard) {
        screen = .deskIsle(card)
        lastCardPixels = nil
        status = nativePet == .active ? "板端绘制 · \(card.title)" : "已连接 · \(card.title)"
        detail = ""
        measuredAt = ProcessInfo.processInfo.systemUptime; measuredFrames = 0
    }

    private func connectionLost(_ error: Error) {
        petLog.info("Screen connection lost: \(error.localizedDescription, privacy: .public)")
        screen = nil
        invalidateSkin()
        releasePackage()
        status = error.localizedDescription
        detail = "连接恢复后会自动继续。"
        nextAttempt = ProcessInfo.processInfo.systemUptime + 2
    }

    private func tickNativePet(now: Double, card: DeskIsleCard, capability: DeskIslePetCapability, token: UUID) {
        let interval = capability.version < 2 || nativeAudioPending ? Self.nativeInputInterval : card.keepaliveInterval
        let inputAt = lastNativeInputAt + interval
        if nativePet == .active, !nativeKeyboardPending, now < inputAt {
            wake(at: inputAt, now: now)
            return
        }
        cancelWake()
        let screen = HardwareScreen.deskIsle(card)
        let revision = skinRevision
        job = Task {
            defer { finishJob(token) }
            guard generation == token, skinRevision == revision else { return }
            do {
                if nativePet == .pending {
                    try await syncNativePet(screen: screen, capability: capability, token: token, revision: revision)
                } else {
                    nativeKeyboardPending = false
                    nativeAudioPending = false
                    lastNativeInputAt = ProcessInfo.processInfo.systemUptime
                    let payload = try nativeInput(limit: capability.maxInput)
                    try await sendPet(.input, payload, screen: screen, capability: capability)
                }
            } catch HardwareSerialError.cardChanged(let card) {
                if generation == token { updateCard(card) }
            } catch HardwareSerialError.petRejected(let reason) {
                guard generation == token, skinRevision == revision else { return }
                if nativePet == .active {
                    if capability.version >= 3, reason == "6" {
                        invalidateSkin()
                        return
                    }
                    // Send a fresh snapshot on the next tick if an input packet was corrupted.
                    if reason == "1" { return }
                }
                petLog.warning("Board rejected native pet: \(reason)")
                nativePet = .fallback
                stopNativeInput()
                detail = "皮肤已切回 Mac 渲染"
            } catch {
                if generation == token { connectionLost(error) }
            }
        }
    }

    private func syncNativePet(screen: HardwareScreen, capability: DeskIslePetCapability, token: UUID, revision: Int) async throws {
        guard let metadata = PluginHost.shared.metadata.first(where: { $0["id"] as? String == selectedID }),
              let path = metadata["directory"] as? String else {
            nativePet = .fallback
            return
        }
        let name = metadata["name"] as? String ?? selectedID
        let cachedIdentity = nativePetIdentity
        if capability.version >= 3, let cachedIdentity {
            status = "正在连接桌宠 · \(name)"
            if try await resumeNativePet(cachedIdentity, screen: screen, capability: capability, token: token, revision: revision) { return }
            guard generation == token, skinRevision == revision else { return }
        }
        status = "正在同步皮肤 · \(name)"
        let bundle: Data
        let identity: NativePetIdentity
        do {
            (bundle, identity) = try await Task.detached(priority: .userInitiated) {
                let bundle = try HardwarePetPack.make(directory: URL(fileURLWithPath: path, isDirectory: true), limit: capability.maxPack)
                return (bundle, NativePetIdentity(size: bundle.count, crc: HardwareFrame.crc32(bundle)))
            }.value
        } catch {
            if generation == token, skinRevision == revision {
                nativePet = .fallback
                detail = error.localizedDescription
                petLog.warning("Native pet pack failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard generation == token, skinRevision == revision else { return }
        nativePetIdentity = identity
        if capability.version >= 3, identity != cachedIdentity {
            if try await resumeNativePet(identity, screen: screen, capability: capability, token: token, revision: revision) { return }
            guard generation == token, skinRevision == revision else { return }
        }
        try await sendPet(.begin, identity.payload, screen: screen, capability: capability)
        for offset in stride(from: 0, to: bundle.count, by: capability.maxChunk) {
            guard generation == token, skinRevision == revision else { return }
            var chunk = Data()
            withUnsafeBytes(of: UInt32(offset).littleEndian) { chunk.append(contentsOf: $0) }
            chunk.append(contentsOf: bundle[offset..<min(offset + capability.maxChunk, bundle.count)])
            try await sendPet(.chunk, chunk, screen: screen, capability: capability)
        }
        guard generation == token, skinRevision == revision else { return }
        try await sendPet(.commit, Data(), screen: screen, capability: capability)
        guard generation == token, skinRevision == revision else { return }
        activateNativePet(identity, resumed: false, screen: screen, capability: capability, token: token, revision: revision)
    }

    private func resumeNativePet(_ identity: NativePetIdentity, screen: HardwareScreen,
                                 capability: DeskIslePetCapability, token: UUID, revision: Int) async throws -> Bool {
        do {
            try await sendPet(.resume, identity.payload, screen: screen, capability: capability)
        } catch HardwareSerialError.petRejected("6") {
            return false
        }
        if generation == token, skinRevision == revision {
            activateNativePet(identity, resumed: true, screen: screen, capability: capability, token: token, revision: revision)
        }
        return true
    }

    private func activateNativePet(_ identity: NativePetIdentity, resumed: Bool, screen: HardwareScreen,
                                   capability: DeskIslePetCapability, token: UUID, revision: Int) {
        (nativeAudio, nativeKeyboard) = PluginHost.shared.hardwareSubscriptions()
        nativePet = .active
        if capability.version >= 2, let nativeKeyboard {
            let signals = nativeKeyboard.eventSignals()
            nativeKeyboardTask = Task { [weak self] in
                for await _ in signals {
                    guard !Task.isCancelled, let self, generation == token, skinRevision == revision else { return }
                    nativeKeyboardPending = true
                    tick()
                }
            }
        }
        if capability.version >= 2, let nativeAudio {
            let signals = nativeAudio.activitySignals()
            nativeAudioTask = Task { [weak self] in
                for await _ in signals {
                    guard !Task.isCancelled, let self, generation == token, skinRevision == revision else { return }
                    nativeAudioPending = true
                    tick()
                }
            }
        }
        releasePackage()
        status = "板端绘制 · \(screen.card?.title ?? "桌屿")"
        let sync = resumed ? "已恢复连接" : "已同步"
        detail = String(format: "皮肤包 %.1f MiB · %@，发送按键与音频特征", Double(identity.size) / 1_048_576, sync)
        if resumed {
            petLog.info("Screen resumed native Lua pet (\(identity.size) bytes)")
        } else {
            petLog.info("Screen activated native Lua pet (\(identity.size) bytes)")
        }
    }

    private func sendPet(_ kind: DeskIslePetMessage, _ payload: Data, screen: HardwareScreen,
                         capability: DeskIslePetCapability) async throws {
        sequence &+= 1
        let sequence = sequence
        let packet = HardwareFrame.nativePet(kind, payload: payload, sequence: sequence, id: capability.id)
        if kind == .input && capability.version >= 2 {
            try await serial.sendPetInput(packet, sequence: sequence, screen: screen)
            return
        }
        if kind == .chunk {
            for _ in 0..<2 {
                do {
                    _ = try await serial.send(packet, sequence: sequence, screen: screen, nativePet: true)
                    return
                } catch HardwareSerialError.petRejected("1") {
                    // A bad CRC leaves the board's upload offset unchanged.
                    continue
                }
            }
        }
        _ = try await serial.send(packet, sequence: sequence, screen: screen, nativePet: true)
    }

    private func nativeInput(limit: Int) throws -> Data {
        try PetInputSnapshot.encode(
            audio: PluginHost.shared.suspended ? nil : nativeAudio?.read(),
            keyboard: PluginHost.shared.suspended ? nil : nativeKeyboard?.read(), limit: limit)
    }
}
