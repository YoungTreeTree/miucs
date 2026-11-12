import XCTest
@testable import MiucsCore

private actor TestTransport: NativePetTransport {
    let card = DeskIsleCard(announcement: "DESKISLE 1 1 512 288 JPEG 98304 3000",
                           pet: DeskIslePetCapability("DESKISLE_PET 3 1 8388608 98304 16384"))!
    var present = false
    var messages: [(DeskIslePetMessage, Data)] = []
    var opens = 0
    var maximumOpen = 0
    var connected = false
    var rejectNextInput = false
    var clearCount = 0

    func connect() async throws -> DeskIsleCard {
        opens += 1
        maximumOpen = max(maximumOpen, connected ? 2 : 1)
        connected = true
        return card
    }

    func send(_ kind: DeskIslePetMessage, payload: Data, card: DeskIsleCard) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(2))
        messages.append((kind, payload))
        switch kind {
        case .resume: if !present { throw HardwareSerialError.petRejected("6") }
        case .commit: present = true
        case .input:
            if rejectNextInput { rejectNextInput = false; present = false; throw HardwareSerialError.petRejected("6") }
        default: break
        }
    }

    func close(clear: Bool) {
        connected = false
        if clear { present = false; clearCount += 1 }
    }
    func loseBoard() { rejectNextInput = true }
    func count(_ kind: DeskIslePetMessage) -> Int { messages.filter { $0.0 == kind }.count }
    func uploadedPack() throws -> Data {
        var result = Data()
        for (_, payload) in messages.filter({ $0.0 == .chunk }) {
            XCTAssertLessThanOrEqual(payload.count, 32 * 1024 + 4)
            let offset = payload.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            XCTAssertEqual(offset, result.count)
            result.append(payload.dropFirst(4))
        }
        return result
    }
    func snapshots() throws -> [[String: Any]] {
        try messages.filter { $0.0 == .input }.map { try JSONSerialization.jsonObject(with: $0.1) as! [String: Any] }
    }
    func keyboardSequences() throws -> [UInt64] {
        try snapshots().flatMap {
            (($0["keyboard"] as? [String: Any])?["events"] as? [[String: Any]] ?? []).compactMap { $0["sequence"] as? UInt64 }
        }
    }
}

final class NativePetTests: XCTestCase {
    func testBundledCatalogAndAllNativePacks() throws {
        let skins = PetCatalog.scan(user: nil)
        XCTAssertEqual(Set(skins.map(\.id)), HardwarePetPack.nativeIDs)
        XCTAssertEqual(skins.first?.id, "pixel-keyboard")
        for skin in skins {
            let bytes = try HardwarePetPack.make(directory: skin.directory, limit: 8 * 1024 * 1024)
            XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "PET1")
            var offset = 4, names = Set<String>()
            while offset < bytes.count {
                XCTAssertLessThanOrEqual(offset + 8, bytes.count)
                let n = Int(bytes[offset + 1])
                let size = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))) }
                XCTAssertLessThanOrEqual(offset + 8 + n + size, bytes.count)
                let name = String(decoding: bytes[(offset + 8)..<(offset + 8 + n)], as: UTF8.self)
                XCTAssertTrue(names.insert(name).inserted)
                offset += 8 + n + size
            }
            XCTAssertEqual(offset, bytes.count)
            XCTAssertTrue(names.contains("manifest.json"))
            XCTAssertTrue(names.contains("main.lua"))
        }
    }

    func testCatalogRejectsEscapingEntryAndSymlinkManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let skin = root.appendingPathComponent("test")
        try FileManager.default.createDirectory(at: skin, withIntermediateDirectories: true)
        let manifest = skin.appendingPathComponent("manifest.json")
        let json = "{\"id\":\"pixel-keyboard\",\"name\":\"Unsafe\",\"api\":1,\"entry\":\"../main.lua\",\"inputs\":[\"keyboard\"]}"
        try Data(json.utf8).write(to: manifest)
        XCTAssertTrue(PetCatalog.scan(builtin: root, user: nil).isEmpty)
        try FileManager.default.removeItem(at: manifest)
        let outside = root.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        XCTAssertTrue(PetCatalog.scan(builtin: root, user: nil).isEmpty)
    }

    func testInputBurstIsBoundedAndReportsDiscardedEvents() throws {
        let channel = KeyboardChannel()
        let id = UUID()
        channel.reset(sessionID: id, state: .running)
        let subscription = channel.subscribe()
        for _ in 0..<64 {
            channel.publish(KeyboardRawEvent(kind: .pressed, keyCode: 0, modifiers: []), sessionID: id)
            channel.publish(KeyboardRawEvent(kind: .released, keyCode: 0, modifiers: []), sessionID: id)
        }
        let payload = try PetInputSnapshot.encode(audio: nil, keyboard: subscription.read(), limit: 4096)
        XCTAssertLessThanOrEqual(payload.count, 4096)
        let json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let keys = json["keyboard"] as! [String: Any]
        XCTAssertEqual((keys["events"] as? [Any])?.count, 0)
        XCTAssertEqual(keys["droppedEventCount"] as? Int, 128)
        XCTAssertEqual((keys["heldKeys"] as? [Any])?.count, 0)
    }

    @MainActor
    func testSessionPreservesKeyOrderAndClosesWithoutRendering() async throws {
        let transport = TestTransport(), session = NativePetSession()
        let audio = FeatureChannel(), keys = KeyboardChannel()
        let id = UUID()
        keys.reset(sessionID: id, state: .running)
        let skin = PetCatalog.scan(user: nil).first!
        session.start(skin: skin, audio: audio, keyboard: keys, transport: transport)
        try await wait { let count = await transport.count(.input); return session.active && count > 0 }
        let uploaded = try await transport.uploadedPack()
        XCTAssertEqual(uploaded, try HardwarePetPack.make(directory: skin.directory, limit: 8 * 1024 * 1024))
        for _ in 0..<12 {
            keys.publish(KeyboardRawEvent(kind: .pressed, keyCode: 0, modifiers: []), sessionID: id)
            keys.publish(KeyboardRawEvent(kind: .released, keyCode: 0, modifiers: []), sessionID: id)
        }
        try await wait { (try? await transport.keyboardSequences().count) == 24 }
        let sequences = try await transport.keyboardSequences()
        XCTAssertEqual(sequences, Array(1...24))
        let before = await transport.count(.input)
        try await Task.sleep(for: .milliseconds(120))
        let after = await transport.count(.input)
        XCTAssertLessThanOrEqual(after - before, 1, "Idle native rendering must not produce a Mac frame loop")
        session.stop()
        await session.waitUntilStopped()
        let cleared = await transport.clearCount
        let connected = await transport.connected
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(connected)
        XCTAssertFalse(session.active)
    }

    @MainActor
    func testRapidSkinChangesSerializeTransportOwnership() async throws {
        let transport = TestTransport(), session = NativePetSession()
        let skins = PetCatalog.scan(user: nil), audio = FeatureChannel(), keys = KeyboardChannel()
        session.start(skin: skins[0], audio: audio, keyboard: keys, transport: transport)
        try await Task.sleep(for: .milliseconds(10))
        for skin in skins.suffix(3) { session.start(skin: skin, audio: audio, keyboard: keys, transport: transport) }
        try await wait { session.active && session.status.contains(skins.last!.name) }
        let maximum = await transport.maximumOpen
        XCTAssertEqual(maximum, 1)
        session.stop(); await session.waitUntilStopped()
    }

    @MainActor
    func testBoardResetReuploadsThenRecovers() async throws {
        let transport = TestTransport(), session = NativePetSession()
        let keys = KeyboardChannel(), audio = FeatureChannel(), id = UUID()
        keys.reset(sessionID: id, state: .running)
        session.start(skin: PetCatalog.scan(user: nil).first!, audio: audio, keyboard: keys, transport: transport)
        try await wait { let count = await transport.count(.input); return session.active && count > 0 }
        await transport.loseBoard()
        keys.publish(KeyboardRawEvent(kind: .pressed, keyCode: 0, modifiers: []), sessionID: id)
        try await wait { (await transport.count(.commit)) >= 2 && session.active }
        let opens = await transport.opens
        XCTAssertGreaterThanOrEqual(opens, 2)
        session.stop(); await session.waitUntilStopped()
    }

    @MainActor
    func testReleasingSessionStopsItsTasksAndClosesTransport() async throws {
        let transport = TestTransport(), audio = FeatureChannel(), keys = KeyboardChannel()
        var session: NativePetSession? = NativePetSession()
        weak var weakSession = session
        session?.start(skin: PetCatalog.scan(user: nil).first!, audio: audio, keyboard: keys, transport: transport)
        try await wait { session?.active == true }
        session = nil
        XCTAssertNil(weakSession)
        try await wait { await transport.clearCount == 1 }
        let connected = await transport.connected
        XCTAssertFalse(connected)
    }

    @MainActor
    private func wait(_ ready: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !(await ready()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Native pet state did not converge")
                throw CocoaError(.userCancelled)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
