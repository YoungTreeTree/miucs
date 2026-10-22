import AppKit

/// A deliberately fictional, empty desktop, drawn entirely from constants.
/// The cursor and selection illustrate click-through; they do not inject UI events.
@MainActor
enum DemoDesktop {
    static let width = 960
    static let height = 600
    static let widget = NSRect(x: 508, y: 264, width: 400, height: 260)

    static func drawBackground() {
        let canvas = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [color(0.87, 0.90, 0.90), color(0.73, 0.81, 0.83), color(0.84, 0.88, 0.87)])!
            .draw(in: canvas, angle: -25)
        let sand = NSBezierPath()
        sand.move(to: NSPoint(x: -40, y: 120))
        sand.curve(to: NSPoint(x: 1000, y: 474), controlPoint1: NSPoint(x: 350, y: 80), controlPoint2: NSPoint(x: 560, y: 520))
        sand.line(to: NSPoint(x: 1000, y: 650)); sand.line(to: NSPoint(x: -40, y: 650)); sand.close()
        NSGradient(colors: [color(0.94, 0.91, 0.84), color(0.84, 0.87, 0.84)])!.draw(in: sand, angle: 60)
        let blue = NSBezierPath()
        blue.move(to: NSPoint(x: 400, y: -20))
        blue.curve(to: NSPoint(x: 1020, y: 388), controlPoint1: NSPoint(x: 410, y: 230), controlPoint2: NSPoint(x: 760, y: 210))
        blue.line(to: NSPoint(x: 1020, y: -20)); blue.close()
        NSGradient(colors: [color(0.73, 0.81, 0.84), color(0.86, 0.89, 0.88)])!.draw(in: blue, angle: -30)
        drawMenuBar()
        drawDock()
    }

    static func drawMenuBar() {
        color(1, 1, 1, 0.30).setFill()
        NSRect(x: 0, y: 0, width: width, height: 27).fill()
        symbol("apple.logo", in: NSRect(x: 17, y: 5, width: 14, height: 16), tint: color(0.19, 0.23, 0.24))
        text("Finder", x: 45, y: 6, bold: true)
        for (label, x) in [("File", 104.0), ("Edit", 142), ("View", 183), ("Go", 230), ("Window", 264), ("Help", 332)] {
            text(label, x: x, y: 6)
        }
        symbol("waveform", in: NSRect(x: 786, y: 6, width: 17, height: 15), tint: color(0.24, 0.28, 0.29))
        symbol("wifi", in: NSRect(x: 821, y: 6, width: 17, height: 15), tint: color(0.24, 0.28, 0.29))
        symbol("battery.100percent", in: NSRect(x: 852, y: 6, width: 23, height: 15), tint: color(0.24, 0.28, 0.29))
        text("10:09", x: 897, y: 6)
    }

    static func drawDock() {
        let dock = NSBezierPath(roundedRect: NSRect(x: 362, y: 538, width: 236, height: 52), xRadius: 15, yRadius: 15)
        color(1, 1, 1, 0.30).setFill(); dock.fill()
        color(1, 1, 1, 0.55).setStroke(); dock.lineWidth = 0.8; dock.stroke()
        let icons: [(String, NSColor)] = [("face.smiling", color(0.32, 0.62, 0.82)),
                                         ("safari", color(0.30, 0.58, 0.76)),
                                         ("music.note", color(0.80, 0.43, 0.49)),
                                         ("gearshape", color(0.56, 0.60, 0.62)),
                                         ("trash", color(0.68, 0.71, 0.70))]
        for (i, icon) in icons.enumerated() {
            let rect = NSRect(x: 372 + Double(i) * 44, y: 547, width: 34, height: 34)
            icon.1.setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            symbol(icon.0, in: rect.insetBy(dx: 6, dy: 6), tint: .white)
        }
    }

    static func cursor(at time: Double) -> NSPoint {
        let start = NSPoint(x: 450, y: 284), anchor = NSPoint(x: 536, y: 342)
        let end = NSPoint(x: 862, y: 504), rest = NSPoint(x: 437, y: 242)
        switch time {
        case ..<1.2: return interpolate(start, anchor, time / 1.2)
        case ..<3.8: return interpolate(anchor, end, (time - 1.2) / 2.6)
        case ..<4.2: return end
        case ..<5.8: return interpolate(end, rest, (time - 4.2) / 1.6)
        case ..<8: return rest
        default: return interpolate(rest, start, (time - 8) / 2)
        }
    }

    static func drawSelection(at time: Double) {
        guard (1.2..<4.2).contains(time) else { return }
        let anchor = NSPoint(x: 536, y: 342), tip = cursor(at: time)
        let selection = NSRect(x: anchor.x, y: anchor.y,
                               width: max(1, tip.x - anchor.x), height: max(1, tip.y - anchor.y))
        color(0.20, 0.48, 0.75, 0.10).setFill(); selection.fill()
        color(0.24, 0.47, 0.67, 0.72).setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 0.9; outline.stroke()
    }

    static func drawCursor(at time: Double) {
        let p = cursor(at: time), cursor = NSBezierPath()
        cursor.move(to: p)
        for offset in [(0.0, 20.0), (5, 15), (9, 24), (12, 22), (8, 14), (16, 14)] {
            cursor.line(to: NSPoint(x: p.x + offset.0, y: p.y + offset.1))
        }
        cursor.close()
        color(0.12, 0.14, 0.15).setFill(); cursor.fill()
        color(1, 1, 1, 0.95).setStroke(); cursor.lineJoinStyle = .round; cursor.lineWidth = 1.2; cursor.stroke()
    }

    static func interpolate(_ a: NSPoint, _ b: NSPoint, _ progress: Double) -> NSPoint {
        let t = min(max(progress, 0), 1), eased = t * t * (3 - 2 * t)
        return NSPoint(x: a.x + (b.x - a.x) * eased, y: a.y + (b.y - a.y) * eased)
    }

    static func text(_ label: String, x: Double, y: Double, bold: Bool = false) {
        (label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
            .foregroundColor: color(0.20, 0.24, 0.25)])
    }

    static func symbol(_ name: String, in rect: NSRect, tint: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let source = NSRect(origin: .zero, size: image.size)
        let colored = NSImage(size: image.size, flipped: false) { _ in
            image.draw(in: source)
            tint.setFill(); source.fill(using: .sourceAtop)
            return true
        }
        colored.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
    }

    static func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }
}
