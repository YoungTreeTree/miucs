import Foundation
import CoreGraphics
import ImageIO

@main
enum TransportTests {
    static func main() async throws {
        if CommandLine.arguments.count == 3 {
            let port = CommandLine.arguments[1], mode = CommandLine.arguments[2]
            let serial = HardwareSerial()
            let screen = try await serial.connect(path: port)
            if mode == "desk-isle" {
                try await testDeskIsle(serial: serial, screen: screen)
                await serial.close()
                return
            }
            if mode == "desk-isle-input" {
                try await testPetInput(serial: serial, screen: screen)
                await serial.close()
                return
            }
            if mode == "desk-isle-resume" {
                try await testPetResume(serial: serial, screen: screen)
                return
            }
            precondition(screen == .miucs)
            let payload = Data([0xff, 0xd8, 0x12, 0x34, 0xff, 0xd9])
            let packet = HardwareFrame.packet(jpeg: payload, sequence: 42)!
            do {
                let ms = try await serial.send(packet, sequence: 42)
                precondition(mode == "ok" && ms == 17)
                print("PASS fragmented handshake, packet bytes, ignored stale ACK and matching ACK")
            } catch {
                guard mode == "timeout" || mode == "disconnect" else { throw error }
                print("PASS \(mode): \(error.localizedDescription)")
            }
            await serial.close()
            return
        }
        precondition(HardwareFrame.crc32(Data("123456789".utf8)) == 0xcbf43926)
        let maximum = Data((0..<HardwareFrame.maxJPEG).map { UInt8(truncatingIfNeeded: $0) })
        precondition(HardwareFrame.crc32(maximum) == 0xc790bff6) // Independent zlib vector.
        precondition(HardwareFrame.packet(jpeg: Data(count: HardwareFrame.maxJPEG + 1), sequence: 0) == nil)
        let output = URL(fileURLWithPath: "build/hardware-tests")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Asymmetric color blocks expose mirroring/rotation and alpha handling.
        var pixels = Data(count: 800 * 460 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let p = buffer.bindMemory(to: UInt8.self)
            for y in 0..<460 { for x in 0..<800 {
                let i = (y * 800 + x) * 4
                let color: [UInt8] = y < 230 ? (x < 400 ? [0,0,255,255] : [0,255,0,255]) : (x < 400 ? [255,0,0,255] : [0,0,0,0])
                for c in 0..<4 { p[i+c] = color[c] }
            } }
        }
        for orientation in HardwareOrientation.allCases {
            let jpeg = HardwareFrame.jpeg(bgra: pixels, width: 800, height: 460, orientation: orientation)!
            precondition(jpeg.count <= HardwareFrame.maxJPEG)
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(image.width == 720 && image.height == 1280)
            try jpeg.write(to: output.appendingPathComponent("orientation-\(orientation.rawValue).jpg"))
        }
        print("PASS CRC standard vector, size bounds, JPEG dimensions and all four orientations")
    }

    private static func testDeskIsle(serial: HardwareSerial, screen: HardwareScreen) async throws {
        let card = screen.card!
        precondition(card.id == 7 && card.width == 512 && card.height == 288 && card.maxJPEG == 98_304)
        precondition(card.keepaliveInterval == 1 && !card.supportsAlpha && card.pet == nil)
        precondition(HardwareFrame.packet(jpeg: Data(count: card.maxJPEG + 1), sequence: 0, screen: screen) == nil)

        func frame(screen: HardwareScreen, sequence: UInt32) -> Data {
            var pixels = Data()
            for _ in 0..<36 {
                for x in 0..<72 {
                    let bgra: [UInt8] = x < 24 ? [0, 0, 0, 0] : x < 48 ? [255, 255, 255, 255] : [0, 0, 128, 128]
                    pixels.append(contentsOf: bgra)
                }
            }
            return HardwareFrame.packet(bgra: pixels, width: 72, height: 36, orientation: .landscapeReverse,
                                        sequence: sequence, screen: screen)!
        }

        let firstMS = try await serial.send(frame(screen: screen, sequence: 42), sequence: 42, screen: screen)
        precondition(firstMS == 17)
        let idleMS = try await serial.send(HardwareFrame.keepalive(sequence: 43, card: card), sequence: 43, screen: screen)
        precondition(idleMS == 0)

        let updated: HardwareScreen
        do {
            _ = try await serial.send(frame(screen: screen, sequence: 44), sequence: 44, screen: screen)
            fatalError("Sent a frame with the old dimensions")
        } catch HardwareSerialError.cardChanged(let card) {
            precondition(card.id == 9 && card.width == 384 && card.height == 224 && card.maxJPEG == 16_384)
            precondition(card.keepaliveInterval == 0.6 && card.supportsAlpha)
            precondition(card.pet?.version == 2 && card.pet?.maxPack == 8 * 1024 * 1024)
            updated = .deskIsle(card)
        }
        let alphaPacket = frame(screen: updated, sequence: 45)
        let jpegLength = alphaPacket.withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: alphaPacket.count - 4, as: UInt32.self)))
        }
        let jpeg = alphaPacket.subdata(in: 24..<(24 + jpegLength))
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = canvas.data!.assumingMemoryBound(to: UInt8.self).advanced(by: image.height / 2 * canvas.bytesPerRow)
        precondition(row[image.width / 6 * 4 + 2] < 8)
        precondition(row[image.width / 2 * 4] > 247 && row[image.width / 2 * 4 + 2] > 247)
        precondition((120...136).contains(row[(image.width * 5 / 6) * 4 + 2]))
        let updatedMS = try await serial.send(alphaPacket, sequence: 45, screen: updated)
        precondition(updatedMS == 19)
        print("PASS DeskIsle legacy frames, keepalive, matching ACK, alpha and native pet negotiation")
    }

    private static func testPetInput(serial: HardwareSerial, screen: HardwareScreen) async throws {
        let card = screen.card!
        func send(_ sequence: UInt32, _ payload: String) async throws {
            let packet = HardwareFrame.nativePet(.input, payload: Data(payload.utf8), sequence: sequence, id: card.id)
            try await serial.sendPetInput(packet, sequence: sequence, screen: screen)
        }

        try await send(41, #"{"event":"pressed"}"#)
        try await send(42, #"{"event":"released"}"#)
        let keepalive = HardwareFrame.keepalive(sequence: 43, card: card)
        let processing = try await serial.send(keepalive, sequence: 43, screen: screen)
        precondition(processing == 17)

        try await send(UInt32.max, "{}")
        try await send(0, "{}")
        do {
            for sequence: UInt32 in 1...25 {
                try await Task.sleep(for: .milliseconds(20))
                try await send(sequence, "{}")
            }
            fatalError("Missed input rejection")
        } catch HardwareSerialError.petRejected("5") {
            print("PASS ordered native input before ACKs, matching control reply and input rejection across wraparound")
        }
    }

    private static func testPetResume(serial: HardwareSerial, screen: HardwareScreen) async throws {
        let card = screen.card!
        precondition(card.pet?.version == 3 && card.pet?.maxPack == 8 * 1024 * 1024)
        let identity = Data([0x39, 0x30, 0, 0, 0x78, 0x56, 0x34, 0x12])
        let miss = HardwareFrame.nativePet(.resume, payload: identity, sequence: 51, id: card.id)
        do {
            _ = try await serial.send(miss, sequence: 51, screen: screen, nativePet: true)
            fatalError("Missed missing-skin status")
        } catch HardwareSerialError.petRejected("6") {}
        let hit = HardwareFrame.nativePet(.resume, payload: identity, sequence: 52, id: card.id)
        let processing = try await serial.send(hit, sequence: 52, screen: screen, nativePet: true)
        precondition(processing == 2)
        await serial.close(clearing: screen, sequence: 53)
        print("PASS native pet v3 negotiation, missing skin, resume and clear")
    }
}
