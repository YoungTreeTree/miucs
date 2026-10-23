import Foundation

/// Opaque, device-independent pencil ink. Alpha remains the renderer's job.
struct PencilColor: Codable, Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        func component(_ value: Double) -> Double {
            value.isFinite ? min(max(value, 0), 1) : 0
        }
        self.red = component(red)
        self.green = component(green)
        self.blue = component(blue)
    }

    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [3, 6].contains(digits.count), digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
               Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    func shaded(by amount: Double) -> PencilColor {
        PencilColor(red: red * amount, green: green * amount, blue: blue * amount)
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let red = try values.decode(Double.self, forKey: .red)
        let green = try values.decode(Double.self, forKey: .green)
        let blue = try values.decode(Double.self, forKey: .blue)
        guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Ink components must be within 0...1"))
        }
        self.init(red: red, green: green, blue: blue)
    }
}

enum PencilPart: String, CaseIterable, Identifiable, Sendable {
    case bird, gates, notes, scenery, trail
    var id: String { rawValue }
    var name: String {
        switch self {
        case .bird: "小鸟"
        case .gates: "管道"
        case .notes: "音符与文字"
        case .scenery: "云朵与地面"
        case .trail: "飞行尾迹"
        }
    }
    var symbol: String {
        switch self {
        case .bird: "bird"
        case .gates: "rectangle.split.1x2"
        case .notes: "music.note"
        case .scenery: "cloud"
        case .trail: "sparkles"
        }
    }
}

struct PencilPalette: Codable, Equatable, Sendable {
    var bird: PencilColor
    var gates: PencilColor
    var notes: PencilColor
    var scenery: PencilColor
    var trail: PencilColor

    subscript(_ part: PencilPart) -> PencilColor {
        get {
            switch part {
            case .bird: bird
            case .gates: gates
            case .notes: notes
            case .scenery: scenery
            case .trail: trail
            }
        }
        set {
            switch part {
            case .bird: bird = newValue
            case .gates: gates = newValue
            case .notes: notes = newValue
            case .scenery: scenery = newValue
            case .trail: trail = newValue
            }
        }
    }

    static let graphite = PencilPalette(
        bird: PencilColor(red: 0.24, green: 0.235, blue: 0.22),
        gates: PencilColor(red: 0.24, green: 0.235, blue: 0.22),
        notes: PencilColor(red: 0.24, green: 0.24, blue: 0.24),
        scenery: PencilColor(red: 0.24, green: 0.235, blue: 0.22),
        trail: PencilColor(red: 0.24, green: 0.235, blue: 0.22))
}

struct PencilPalettePreset: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let palette: PencilPalette

    private static func inks(_ hexes: [String]) -> PencilPalette {
        let colors = hexes.map { PencilColor(hex: $0)! }
        return PencilPalette(bird: colors[0], gates: colors[1], notes: colors[2],
                             scenery: colors[3], trail: colors[4])
    }
    static let all: [PencilPalettePreset] = [
        .init(id: "graphite", name: "原生石墨", subtitle: "一支铅笔的纯粹", palette: .graphite),
        .init(id: "forest", name: "森林来信", subtitle: "苔绿 · 松针 · 暖棕",
              palette: inks(["56705B", "788367", "6E5D49", "8A967B", "B2986B"])),
        .init(id: "coast", name: "海盐微风", subtitle: "海蓝 · 青灰 · 沙色",
              palette: inks(["467C92", "6F9998", "4F7087", "8FA5A6", "C09B70"])),
        .init(id: "sunset", name: "日落橘子", subtitle: "赭橙 · 陶红 · 金黄",
              palette: inks(["BF704B", "A58268", "A85F58", "B59B7E", "CD9A4F"])),
        .init(id: "lavender", name: "紫色梦境", subtitle: "鸢尾 · 雾紫 · 玫瑰",
              palette: inks(["8B72A2", "A28BA9", "795F91", "A29BAE", "BD839B"])),
        .init(id: "moonlight", name: "月光粉笔", subtitle: "柔白与浅蓝，适合深色桌面",
              palette: inks(["ECE4D5", "B5CDCF", "E4CCAA", "BAC3CE", "D4BDD9"]))
    ]
}
