import Foundation

/// Opaque, device-independent visualization ink. Alpha remains the renderer's job.
struct VisualizationColor: Codable, Equatable, Hashable, Sendable {
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
    func shaded(by amount: Double) -> VisualizationColor {
        VisualizationColor(red: red * amount, green: green * amount, blue: blue * amount)
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


/// A single shared ink; each renderer keeps its own line weights and opacity.
struct VisualizationAppearance: Equatable, Sendable {
    let ink: VisualizationColor
    static let graphite = VisualizationAppearance(ink: VisualizationInk.graphite.color)
}

enum VisualizationInk: String, CaseIterable, Identifiable, Sendable {
    case graphite, blue, green, orange, violet
    var id: String { rawValue }
    var name: String {
        switch self {
        case .graphite: "石墨灰"
        case .blue: "雾蓝"
        case .green: "苔绿"
        case .orange: "赭橙"
        case .violet: "雾紫"
        }
    }
    var color: VisualizationColor {
        switch self {
        case .graphite: VisualizationColor(red: 0.24, green: 0.24, blue: 0.24)
        case .blue: VisualizationColor(hex: "4F7087")!
        case .green: VisualizationColor(hex: "56705B")!
        case .orange: VisualizationColor(hex: "BF704B")!
        case .violet: VisualizationColor(hex: "8B72A2")!
        }
    }
    var appearance: VisualizationAppearance { VisualizationAppearance(ink: color) }
    static func nearest(to color: VisualizationColor) -> VisualizationInk {
        allCases.min { a, b in
            func distance(_ ink: VisualizationColor) -> Double {
                pow(ink.red - color.red, 2) + pow(ink.green - color.green, 2) + pow(ink.blue - color.blue, 2)
            }
            return distance(a.color) < distance(b.color)
        }!
    }
}
