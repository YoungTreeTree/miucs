import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum HardwareOrientation: Int, CaseIterable, Identifiable, Sendable {
    case portrait = 0, landscape = 1, portraitReverse = 2, landscapeReverse = 3
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .portrait: "竖屏"
        case .landscape: "横屏"
        case .portraitReverse: "竖屏 · 反向"
        case .landscapeReverse: "横屏 · 反向"
        }
    }
    public var width: Int { rawValue % 2 == 0 ? 720 : 1280 }
    public var height: Int { rawValue % 2 == 0 ? 1280 : 720 }
}

public struct DeskIslePetCapability: Equatable, Sendable {
    public let version: Int
    public let id: UInt16
    public let maxPack: Int
    public let maxChunk: Int
    public let maxInput: Int

    public init?(_ line: String) {
        let fields = line.split(separator: " ")
        guard fields.count == 6, fields[0] == "DESKISLE_PET",
              let version = Int(fields[1]), (1...3).contains(version),
              let id = UInt16(fields[2]), id > 0,
              let pack = Int(fields[3]), (4...(version == 1 ? 6 : 8) * 1024 * 1024).contains(pack),
              let chunk = Int(fields[4]), (1024...96 * 1024).contains(chunk),
              let input = Int(fields[5]), (4096...16 * 1024).contains(input) else { return nil }
        self.version = version
        self.id = id
        maxPack = pack
        maxChunk = chunk
        maxInput = input
    }
}

public enum DeskIslePetMessage: UInt8, Sendable {
    case begin = 8, chunk, commit, input
    case resume = 14, clear
}

public struct DeskIsleCard: Equatable, Sendable {
    public let id: UInt16
    public let width: UInt16
    public let height: UInt16
    public let maxJPEG: Int
    public let leaseMS: UInt32
    public let supportsAlpha: Bool
    public let pet: DeskIslePetCapability?

    public init?(announcement: String, alphaCardID: UInt16? = nil, pet: DeskIslePetCapability? = nil) {
        let fields = announcement.split(whereSeparator: \.isWhitespace)
        // A card must fit within the 720 × 1280 panel.
        guard fields.count == 8, fields[0] == "DESKISLE", fields[1] == "1", fields[5] == "JPEG",
              let id = UInt16(fields[2]), id > 0,
              let width = UInt16(fields[3]), (1...720).contains(width),
              let height = UInt16(fields[4]), (1...1280).contains(height),
              let maxJPEG = UInt32(fields[6]), maxJPEG >= 4,
              let leaseMS = UInt32(fields[7]), leaseMS > 0 else { return nil }
        self.id = id
        self.width = width
        self.height = height
        self.maxJPEG = Int(maxJPEG)
        self.leaseMS = leaseMS
        supportsAlpha = id == alphaCardID
        self.pet = id == pet?.id ? pet : nil
    }

    public var title: String { "桌屿 \(width)×\(height)" }
    public var leaseDuration: Double { Double(leaseMS) / 1000 }
    public var keepaliveInterval: Double { min(1, leaseDuration / 2) }
}

public enum HardwareScreen: Equatable, Sendable {
    case miucs
    case deskIsle(DeskIsleCard)

    public var card: DeskIsleCard? {
        if case let .deskIsle(card) = self { return card }
        return nil
    }

    public func fitScale(width: Double, height: Double, orientation: HardwareOrientation) -> Double {
        let viewportWidth = card.map { Int($0.width) } ?? orientation.width
        let viewportHeight = card.map { Int($0.height) } ?? orientation.height
        let padding = card == nil ? 32 : 16
        return min(Double(max(1, viewportWidth - padding)) / width,
                   Double(max(1, viewportHeight - padding)) / height)
    }
}

public enum HardwareFrame {
    public static let maxJPEG = 262_144
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xedb88320 : 0) }
        return value
    }
    public static func crc32(_ bytes: Data) -> UInt32 {
        var value = UInt32.max
        for byte in bytes { value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 0xff)] }
        return ~value
    }
    public static func packet(jpeg: Data, sequence: UInt32, screen: HardwareScreen = .miucs) -> Data? {
        guard (4...(screen.card?.maxJPEG ?? maxJPEG)).contains(jpeg.count) else { return nil }
        if let card = screen.card {
            guard jpeg.starts(with: [0xff, 0xd8]) else { return nil }
            return packet(magic: "ISLE", kind: 1, cardID: card.id, sequence: sequence,
                          payload: jpeg, width: card.width, height: card.height)
        }
        return packet(magic: "MIUC", kind: 1, cardID: 0, sequence: sequence, payload: jpeg, width: 720, height: 1280)
    }
    public static func packet(bgra: Data, width: Int, height: Int, orientation: HardwareOrientation,
                       sequence: UInt32, screen: HardwareScreen) -> Data? {
        guard let card = screen.card, card.supportsAlpha else {
            return jpeg(bgra: bgra, width: width, height: height, orientation: orientation, screen: screen)
                .flatMap { packet(jpeg: $0, sequence: sequence, screen: screen) }
        }
        guard let canvas = bitmap(bgra: bgra, width: width, height: height, orientation: orientation,
                                  screen: screen, transparent: true), let base = canvas.data else { return nil }
        let rendered = Data(bytes: base, count: canvas.bytesPerRow * canvas.height)
        // Ignore the alpha byte for JPEG so its channels retain their premultiplied values.
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: rendered as CFData),
              let color = CGImage(width: canvas.width, height: canvas.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: canvas.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let jpeg = encodeJPEG(color, screen: screen) else { return nil }
        var payload = jpeg
        payload.append(alphaMask(bgra: rendered))
        // Keep the JPEG at the DMA-aligned start of the payload.
        withUnsafeBytes(of: UInt32(jpeg.count).littleEndian) { payload.append(contentsOf: $0) }
        return packet(magic: "ISLE", kind: 5, cardID: card.id, sequence: sequence,
                      payload: payload, width: card.width, height: card.height)
    }
    public static func keepalive(sequence: UInt32, card: DeskIsleCard) -> Data {
        packet(magic: "ISLE", kind: 2, cardID: card.id, sequence: sequence, payload: Data(), width: 0, height: 0)
    }
    public static func nativePet(_ kind: DeskIslePetMessage, payload: Data, sequence: UInt32, id: UInt16) -> Data {
        packet(magic: "ISLE", kind: kind.rawValue, cardID: id, sequence: sequence, payload: payload, width: 0, height: 0)
    }
    private static func packet(magic: String, kind: UInt8, cardID: UInt16, sequence: UInt32,
                               payload: Data, width: UInt16, height: UInt16) -> Data {
        var result = Data(magic.utf8)
        result.append(contentsOf: [1, kind])
        withUnsafeBytes(of: cardID.littleEndian) { result.append(contentsOf: $0) }
        for value in [sequence, UInt32(payload.count), crc32(payload)] {
            withUnsafeBytes(of: value.littleEndian) { result.append(contentsOf: $0) }
        }
        for dimension in [width, height] {
            withUnsafeBytes(of: dimension.littleEndian) { result.append(contentsOf: $0) }
        }
        result.append(payload)
        return result
    }

    private static func alphaMask(bgra: Data) -> Data {
        let pixelCount = bgra.count / 4
        var raw = Data(count: pixelCount)
        raw.withUnsafeMutableBytes { (alpha: UnsafeMutableRawBufferPointer) in
            bgra.withUnsafeBytes { (pixels: UnsafeRawBufferPointer) in
                for i in 0..<pixelCount { alpha[i] = pixels[4 * i + 3] }
            }
        }
        return raw.withUnsafeBytes { (alpha: UnsafeRawBufferPointer) -> Data in
            var runs = Data()
            var start = 0
            while start < pixelCount {
                let value = alpha[start]
                let limit = min(start + 255, pixelCount)
                var end = start + 1
                while end < limit && alpha[end] == value { end += 1 }
                if runs.count + 2 >= pixelCount { return raw }
                runs.append(UInt8(end - start))
                runs.append(value)
                start = end
            }
            return runs
        }
    }

    public static func image(bgra: Data, width: Int, height: Int, orientation: HardwareOrientation,
                      screen: HardwareScreen = .miucs) -> CGImage? {
        bitmap(bgra: bgra, width: width, height: height, orientation: orientation, screen: screen, transparent: false)?
            .makeImage()
    }
    private static func bitmap(bgra: Data, width: Int, height: Int, orientation: HardwareOrientation,
                               screen: HardwareScreen, transparent: Bool) -> CGContext? {
        guard width > 0, height > 0, bgra.count == width * height * 4,
              let provider = CGDataProvider(data: bgra as CFData) else { return nil }
        let outputWidth = screen.card.map { Int($0.width) } ?? 720
        let outputHeight = screen.card.map { Int($0.height) } ?? 1280
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                                      bytesPerRow: outputWidth * 4, space: space, bitmapInfo: info) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        if transparent {
            context.clear(bounds)
        } else {
            context.setFillColor(CGColor(red: 0.965, green: 0.965, blue: 0.95, alpha: 1))
            context.fill(bounds)
        }
        context.translateBy(x: CGFloat(outputWidth) / 2, y: CGFloat(outputHeight) / 2)
        if screen.card == nil { context.rotate(by: CGFloat(orientation.rawValue) * .pi / 2) }
        let scale = screen.fitScale(width: Double(width), height: Double(height), orientation: orientation)
        let w = Double(width) * scale, h = Double(height) * scale
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return context
    }
    public static func jpeg(bgra: Data, width: Int, height: Int, orientation: HardwareOrientation,
                     screen: HardwareScreen = .miucs) -> Data? {
        guard let image = image(bgra: bgra, width: width, height: height, orientation: orientation, screen: screen) else { return nil }
        return encodeJPEG(image, screen: screen)
    }
    private static func encodeJPEG(_ image: CGImage, screen: HardwareScreen) -> Data? {
        let qualities = screen.card == nil ? [0.65, 0.50, 0.35] : [0.65, 0.50, 0.35, 0.20, 0.05]
        for quality in qualities {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if bytes.length <= (screen.card?.maxJPEG ?? maxJPEG) { return bytes as Data }
        }
        return nil
    }
}
