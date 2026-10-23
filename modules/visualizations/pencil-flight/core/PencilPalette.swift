import Foundation

/// Legacy flight palettes reuse the shared, platform-neutral color value.
typealias PencilColor = VisualizationColor

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

    init(ink: VisualizationColor) {
        bird = ink; gates = ink; notes = ink; scenery = ink; trail = ink
    }

    init(bird: PencilColor, gates: PencilColor, notes: PencilColor, scenery: PencilColor, trail: PencilColor) {
        self.bird = bird; self.gates = gates; self.notes = notes; self.scenery = scenery; self.trail = trail
    }

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
