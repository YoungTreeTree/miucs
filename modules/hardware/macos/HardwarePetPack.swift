import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum HardwarePetPack {
    public static let nativeIDs: Set<String> = [
        "heiji-kazuha", "inuyasha", "muffin-puppies", "niulai-keyboard",
        "pixel-keyboard", "yuru-camp", "zelda-guardian"
    ]

    public static func supports(_ id: String, on capability: DeskIslePetCapability) -> Bool {
        capability.version == 1 ? id == "yuru-camp" : nativeIDs.contains(id)
    }

    public static func make(directory: URL, limit: Int) throws -> Data {
        let fileKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: fileKeys,
                                                               options: [.skipsHiddenFiles]) else {
            throw HardwareSerialError.message("无法读取桌宠皮肤")
        }
        var files: [(name: String, kind: UInt8, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(fileKeys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let name = String(url.path.dropFirst(directory.path.count + 1))
            let kind: UInt8
            switch (name, url.pathExtension.lowercased()) {
            case ("manifest.json", _): kind = 4
            case (_, "lua"): kind = 1
            case (_, "png") where name.hasPrefix("assets/"): kind = 2
            case (_, "ttf") where name.hasPrefix("assets/"): kind = 3
            default: continue
            }
            guard !name.isEmpty, name.utf8.count < 80, name.utf8.allSatisfy({ (32...126).contains($0) }),
                  files.count < 32, let size = values.fileSize, (1...12 * 1024 * 1024).contains(size) else {
                throw HardwareSerialError.message("桌宠皮肤文件超过小屏限制")
            }
            files.append((name, kind, url))
        }
        guard files.contains(where: { $0.kind == 4 }) else {
            throw HardwareSerialError.message("找不到桌宠皮肤描述")
        }
        var pack = Data("PET1".utf8)
        for file in files.sorted(by: { $0.name < $1.name }) {
            let bytes: Data
            switch file.kind {
            case 2: bytes = try atlas(file.url)
            case 3: bytes = try glyphs(file.url)
            default: bytes = try Data(contentsOf: file.url)
            }
            guard pack.count + 8 + file.name.utf8.count + bytes.count <= limit else {
                throw HardwareSerialError.message("桌宠皮肤包超过小屏限制")
            }
            pack.append(contentsOf: [file.kind, UInt8(file.name.utf8.count), 0, 0])
            withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { pack.append(contentsOf: $0) }
            pack.append(contentsOf: file.name.utf8)
            pack.append(bytes)
        }
        return pack
    }

    private static func atlas(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let originalWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let originalHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(originalWidth), (1...4096).contains(originalHeight),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HardwareSerialError.message("无法读取桌宠图集")
        }
        let divisor = max(originalWidth, originalHeight) <= 256 ? 1 : 2
        let width = (originalWidth + divisor - 1) / divisor
        let height = (originalHeight + divisor - 1) / divisor
        var pixels = Data(count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw HardwareSerialError.message("无法转换桌宠图集") }
        var bytes = Data()
        for value in [originalWidth, originalHeight, width, height] {
            withUnsafeBytes(of: UInt16(value).littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(pixels)
        return bytes
    }

    private static func glyphs(_ url: URL) throws -> Data {
        guard let provider = CGDataProvider(url: url as CFURL), let graphicsFont = CGFont(provider) else {
            throw HardwareSerialError.message("无法读取桌宠字体")
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 24, nil, nil)
        let width = 32, height = 36
        var bytes = Data()
        for ascii in 32...126 {
            var character = UniChar(ascii), glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
                throw HardwareSerialError.message("桌宠字体缺少键帽字形")
            }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            var pixels = Data(count: width * height)
            let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.setShouldSmoothFonts(false)
                var position = CGPoint(x: 2, y: 8)
                CTFontDrawGlyphs(font, &glyph, &position, 1, context)
                return true
            }
            guard rendered else { throw HardwareSerialError.message("无法转换桌宠字形") }
            bytes.append(UInt8(clamping: Int(advance.width.rounded())))
            bytes.append(pixels)
        }
        return bytes
    }
}
