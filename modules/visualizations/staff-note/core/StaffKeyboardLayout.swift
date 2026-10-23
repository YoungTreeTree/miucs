import Foundation

/// Physical positions, independent of characters, input methods and platform virtual key codes.
enum StaffKeyboardKey: String, CaseIterable, Sendable {
    case grave, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9, digit0, minus, equal, backspace
    case tab, q, w, e, r, t, y, u, i, o, p, leftBracket, rightBracket, backslash
    case capsLock, a, s, d, f, g, h, j, k, l, semicolon, quote, returnKey
    case leftShift, z, x, c, v, b, n, m, comma, period, slash, rightShift
    case function, leftControl, leftOption, leftCommand, space, rightCommand, rightOption, rightControl

    var repeats: Bool {
        switch self {
        case .capsLock, .leftShift, .rightShift, .function, .leftControl, .rightControl,
             .leftOption, .rightOption, .leftCommand, .rightCommand: return false
        default: return true
        }
    }
}

enum StaffKeyboardLayout {
    struct Placement: Sendable {
        let key: StaffKeyboardKey
        let row: Int
        let widthUnits: Double
        let x: Double
        let y: Double
    }

    static let placements: [Placement] = {
        let rows: [[(StaffKeyboardKey, Double)]] = [
            [(.grave, 1), (.digit1, 1), (.digit2, 1), (.digit3, 1), (.digit4, 1), (.digit5, 1),
             (.digit6, 1), (.digit7, 1), (.digit8, 1), (.digit9, 1), (.digit0, 1), (.minus, 1), (.equal, 1), (.backspace, 2)],
            [(.tab, 1.5), (.q, 1), (.w, 1), (.e, 1), (.r, 1), (.t, 1), (.y, 1), (.u, 1),
             (.i, 1), (.o, 1), (.p, 1), (.leftBracket, 1), (.rightBracket, 1), (.backslash, 1.5)],
            [(.capsLock, 1.75), (.a, 1), (.s, 1), (.d, 1), (.f, 1), (.g, 1), (.h, 1), (.j, 1),
             (.k, 1), (.l, 1), (.semicolon, 1), (.quote, 1), (.returnKey, 2.25)],
            [(.leftShift, 2.25), (.z, 1), (.x, 1), (.c, 1), (.v, 1), (.b, 1), (.n, 1), (.m, 1),
             (.comma, 1), (.period, 1), (.slash, 1), (.rightShift, 2.75)],
            [(.function, 1.25), (.leftControl, 1.25), (.leftOption, 1.25), (.leftCommand, 1.25),
             (.space, 6.25), (.rightCommand, 1.25), (.rightOption, 1.25), (.rightControl, 1.25)]
        ]
        return rows.enumerated().flatMap { row, keys in
            var left = 0.0
            return keys.map { key, width in
                defer { left += width }
                return Placement(key: key, row: row, widthUnits: width,
                    x: 80 + (left + width / 2) * 680 / 15, y: 36 + Double(row) * 22)
            }
        }
    }()
    static let positions = Dictionary(uniqueKeysWithValues: placements.map { ($0.key, $0) })
}
