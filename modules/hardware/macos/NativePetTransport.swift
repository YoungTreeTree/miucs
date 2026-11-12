import Foundation

/// The embedding host owns discovery and the USB connection. MiucsCore only consumes a logical channel.
public protocol NativePetTransport: Sendable {
    func connect() async throws -> DeskIsleCard
    func send(_ kind: DeskIslePetMessage, payload: Data, card: DeskIsleCard) async throws
    func close(clear: Bool) async
}

public actor SerialPetTransport: NativePetTransport {
    private let serial = HardwareSerial()
    private let open: @Sendable () async throws -> Int32
    private var sequence = UInt32.random(in: 0...UInt32.max)
    private var screen: HardwareScreen?

    public init(open: @escaping @Sendable () async throws -> Int32) { self.open = open }

    public func connect() async throws -> DeskIsleCard {
        let fd = try await open()
        let connected = try await serial.connect(takingOwnershipOf: fd)
        guard let card = connected.card, card.pet != nil else {
            await serial.close()
            throw HardwareSerialError.message("小屏未提供板端桌宠，请更新固件")
        }
        screen = connected
        return card
    }

    public func send(_ kind: DeskIslePetMessage, payload: Data, card: DeskIsleCard) async throws {
        guard let capability = card.pet else { throw HardwareSerialError.message("小屏不支持板端桌宠") }
        sequence &+= 1
        let sequence = sequence
        let packet = HardwareFrame.nativePet(kind, payload: payload, sequence: sequence, id: capability.id)
        if kind == .input, capability.version >= 2 {
            try await serial.sendPetInput(packet, sequence: sequence, screen: .deskIsle(card))
        } else {
            _ = try await serial.send(packet, sequence: sequence, screen: .deskIsle(card), nativePet: true)
        }
    }

    public func close(clear: Bool) async {
        let current = screen
        screen = nil
        if clear, let current {
            sequence &+= 1
            await serial.close(clearing: current, sequence: sequence)
        } else { await serial.close() }
    }
}

public enum PetInputSnapshot {
    public static func encode(audio: FeatureInput?, keyboard: KeyboardInput?, limit: Int,
                              now: Double = ProcessInfo.processInfo.systemUptime) throws -> Data {
        var sound = audio.map(PluginInput.audio) ?? [:]
        var keys = keyboard.map(PluginInput.keyboard) ?? [:]
        func encode() throws -> Data {
            try JSONSerialization.data(withJSONObject: ["now": now, "audio": sound, "keyboard": keys])
        }
        var payload = try encode()
        if payload.count > limit {
            keys["droppedEventCount"] = (keys["droppedEventCount"] as? UInt64 ?? 0)
                + UInt64((keys["events"] as? [Any])?.count ?? 0)
            sound["droppedBeatCount"] = (sound["beats"] as? [Any])?.count ?? 0
            sound["droppedOnsetCount"] = (sound["onsets"] as? [Any])?.count ?? 0
            keys["events"] = []; sound["onsets"] = []; sound["beats"] = []
            payload = try encode()
        }
        guard payload.count <= limit else { throw HardwareSerialError.message("桌宠输入超过小屏限制") }
        return payload
    }
}
