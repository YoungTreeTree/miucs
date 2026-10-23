import AppKit
import CoreText

@MainActor
final class PencilFlightView: NSView {
    private static let gateFade = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    private(set) var world = SoundFlightWorld()
    private(set) var palette = PencilPalette.graphite
    private var inkColors = Dictionary(uniqueKeysWithValues: PencilPart.allCases.map { ($0, PencilPalette.graphite[$0].cgColor) })
    private var eyeColor = PencilPalette.graphite.bird.shaded(by: 0.8).cgColor
    /// Optional local probe; normal rendering records no timing samples.
    var onRender: ((_ seconds: Double, _ timestamp: Double) -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(preview: SoundFlightWorld, palette: PencilPalette = .graphite) {
        world = preview
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Miucs · 铅笔音乐飞鸟")
        updatePalette(palette)
    }
    /// Offscreen tools reuse the same renderer and its bounded drawing caches.
    func updatePreview(_ scene: SoundFlightWorld) { world = scene }
    func updatePalette(_ updated: PencilPalette) {
        guard palette != updated else { return }
        palette = updated
        inkColors = Dictionary(uniqueKeysWithValues: PencilPart.allCases.map { ($0, updated[$0].cgColor) })
        eyeColor = updated.bird.shaded(by: 0.8).cgColor
        // CTLine embeds its ink color; geometry caches can be reused unchanged.
        textCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let started = onRender == nil ? nil : ProcessInfo.processInfo.systemUptime
        defer {
            if let started { onRender?(ProcessInfo.processInfo.systemUptime - started, started) }
        }
        NSGraphicsContext.saveGraphicsState()
        let scale = NSAffineTransform()
        scale.scaleX(by: bounds.width / 400, yBy: bounds.height / 260); scale.concat()
        drawEnvironment()
        drawGates()
        drawParticles()
        drawPuffs()
        drawBird()
        drawMelodyNote()
        drawText(String(world.score), at: NSPoint(x: 354, y: 9), size: 21, opacity: 0.75)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEnvironment() {
        let backgroundWeight = 0.85 - world.brightness * 0.22
        for i in 0..<3 {
            let x = (Double(i) * 171 + 38 - world.distance * (0.10 + Double(i) * 0.025)).truncatingRemainder(dividingBy: 510)
            let position = x < -65 ? x + 510 : x
            let y = 34 + Double(i % 2) * 38
            let cloud = CGMutablePath()
            cloud.move(to: NSPoint(x: position - 24, y: y + 9))
            cloud.addCurve(to: NSPoint(x: position - 14, y: y - 1), control1: NSPoint(x: position - 27, y: y + 1), control2: NSPoint(x: position - 20, y: y - 5))
            cloud.addCurve(to: NSPoint(x: position + 9, y: y - 4), control1: NSPoint(x: position - 13, y: y - 18), control2: NSPoint(x: position + 8, y: y - 19))
            cloud.addCurve(to: NSPoint(x: position + 25, y: y + 9), control1: NSPoint(x: position + 23, y: y - 11), control2: NSPoint(x: position + 31, y: y + 2))
            cloud.addCurve(to: NSPoint(x: position - 24, y: y + 9), control1: NSPoint(x: position + 5, y: y + 12), control2: NSPoint(x: position - 10, y: y + 7))
            pencil(cloud, width: backgroundWeight, opacity: 0.36)
        }
        sketch([NSPoint(x: 8, y: 247), NSPoint(x: 130, y: 247.4), NSPoint(x: 266, y: 246.8), NSPoint(x: 391, y: 247)], seed: 401, width: 0.9, opacity: 0.44)
        for i in 0..<13 {
            let x = (Double(i) * 37 - world.distance * 0.65).truncatingRemainder(dividingBy: 440)
            let px = x < 0 ? x + 440 : x
            let y = 250 + abs(SoundFlightWorld.noise(i, 9)) * 5
            sketch([NSPoint(x: px, y: y), NSPoint(x: px + 3 + Double(i % 3), y: y - 1)], seed: i + 600, width: 0.65, opacity: 0.33)
        }
    }

    private func drawGates() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // Mask the complete pipe drawing, including white underlines and hatching.
        // The bird's x position is the zero-opacity boundary in world-view units.
        let visible = CGRect(x: SoundFlightWorld.birdScreenX, y: 0,
                             width: SoundFlightWorld.width - SoundFlightWorld.birdScreenX,
                             height: SoundFlightWorld.height)
        for gate in world.gates {
            let x = SoundFlightWorld.birdScreenX + gate.x - world.distance
            guard x > SoundFlightWorld.birdScreenX, x < 440 else { continue }
            // Pipes never overlap horizontally. Composite only their narrow strip,
            // rather than allocating and shading the entire right side of the view.
            let strip = CGRect(x: x - 30, y: 0, width: 60, height: 260).intersection(visible)
            guard !strip.isNull else { continue }
            context.saveGState(); context.clip(to: strip)
            context.beginTransparencyLayer(in: strip, auxiliaryInfo: nil)
            draw(gate: gate)
            context.setBlendMode(.destinationIn)
            context.drawLinearGradient(Self.gateFade,
                start: CGPoint(x: SoundFlightWorld.birdScreenX, y: 0),
                end: CGPoint(x: SoundFlightWorld.width, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func draw(gate: FlightGate) {
        let x = SoundFlightWorld.birdScreenX + gate.x - world.distance
        guard x > SoundFlightWorld.birdScreenX, x < 440 else { return }
        let pressure = 1.15 + world.bass * 0.5
        let pulse = world.bass * world.flap
        let halfBody = 17 + pulse * 1.5
        let halfCap = 24 + pulse * 2 // Always inside the reserved halfWidth = 30.
        let upper = gate.openingTop, lower = gate.openingBottom
        let ink = gate.passed ? 0.64 : 0.87
        for side in [-1.0, 1.0] {
            sketch([NSPoint(x: x + side * halfBody, y: -3), NSPoint(x: x + side * halfBody, y: upper - 9)], seed: gate.id * 11 + Int(side) + 1000, width: pressure, opacity: ink, part: .gates)
            sketch([NSPoint(x: x + side * halfBody, y: lower + 9), NSPoint(x: x + side * halfBody, y: 246)], seed: gate.id * 11 + Int(side) + 1100, width: pressure, opacity: ink, part: .gates)
        }
        for (side, pair) in [(upper, -1.0), (lower, 1.0)].enumerated() {
            let (edge, direction) = pair
            sketch([NSPoint(x: x - halfCap, y: edge + direction * 9), NSPoint(x: x - halfCap, y: edge), NSPoint(x: x + halfCap, y: edge), NSPoint(x: x + halfCap, y: edge + direction * 9), NSPoint(x: x - halfCap, y: edge + direction * 9)], seed: gate.id * 17 + side + 1700, width: pressure, opacity: ink, part: .gates)
            for h in 0..<4 {
                let hx = x - halfCap + 5 + Double(h) * 5
                sketch([NSPoint(x: hx, y: edge + direction * 2), NSPoint(x: hx + 3, y: edge + direction * 6)], seed: gate.id + h + 1500, width: 0.7, opacity: 0.35 + world.bass * 0.13, part: .gates)
            }
        }
        for h in 0..<3 {
            let y = upper - 18 - Double(h) * 8
            if y > 5 {
                sketch([NSPoint(x: x + halfBody - 6, y: y), NSPoint(x: x + halfBody - 2, y: y - 3)], seed: gate.id * 3 + h, width: 0.6, opacity: 0.24, part: .gates)
            }
        }
    }

    private func drawMelodyNote() {
        let note = world.melodyNoteName ?? "—"
        let size = 17.0
        let width = textLayout(note, size: size).width
        // Trail the bird without rotating with it, leaving its tail silhouette clear.
        drawText(note, at: NSPoint(x: max(6, SoundFlightWorld.birdScreenX - world.birdHalfWidth - 10 - width),
                                  y: world.birdY - 12),
                 size: size, opacity: world.melodyNoteOpacity)
    }

    private func drawBird() {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: SoundFlightWorld.birdScreenX, yBy: world.birdY)
        transform.rotate(byRadians: world.birdAngle)
        let stretch = world.birdStretch
        transform.scaleX(by: world.birdScale / stretch, yBy: world.birdScale * stretch)
        transform.concat()
        let body = CGMutablePath()
        body.move(to: NSPoint(x: -15, y: 0))
        body.addCurve(to: NSPoint(x: 7, y: -10), control1: NSPoint(x: -14, y: -14), control2: NSPoint(x: 0, y: -15))
        body.addCurve(to: NSPoint(x: 15, y: 1), control1: NSPoint(x: 14, y: -9), control2: NSPoint(x: 15, y: -4))
        body.addCurve(to: NSPoint(x: -15, y: 0), control1: NSPoint(x: 16, y: 15), control2: NSPoint(x: -14, y: 17))
        pencil(body, width: 1.55, opacity: 0.96, part: .bird)
        sketch([NSPoint(x: 14, y: -1), NSPoint(x: 23, y: 2), NSPoint(x: 14, y: 5)], seed: 31, width: 1.35, part: .bird)
        sketch([NSPoint(x: -14, y: 2), NSPoint(x: -23, y: -1), NSPoint(x: -18, y: 7), NSPoint(x: -12, y: 8)], seed: 32, width: 1.3, part: .bird)
        let eye = CGPath(ellipseIn: CGRect(x: 7, y: -5, width: 2.8, height: 3.1), transform: nil)
        if let context = NSGraphicsContext.current?.cgContext {
            context.setStrokeColor(Self.halo); context.setAlpha(0.7); context.setLineWidth(1)
            context.addPath(eye); context.strokePath()
            context.setFillColor(eyeColor); context.setAlpha(0.98)
            context.addPath(eye); context.fillPath(); context.setAlpha(1)
        }
        let wing = CGMutablePath()
        let lift = world.flap * (10 + world.loudness * 9)
        wing.move(to: NSPoint(x: -7, y: 3))
        wing.addCurve(to: NSPoint(x: 1, y: 7 - lift), control1: NSPoint(x: -15, y: 6 - lift), control2: NSPoint(x: -9, y: 17 - lift))
        pencil(wing, width: 1.4, opacity: 0.94, part: .bird)
        if world.flap > 0.35 {
            sketch([NSPoint(x: -13, y: -5 - lift * 0.35), NSPoint(x: -17, y: -8 - lift * 0.45)], seed: 42, width: 0.7, opacity: world.flap * 0.45, part: .bird)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawParticles() {
        for p in world.particles {
            let fade = max(p.life / p.lifetime, 0)
            if p.feather {
                let path = CGMutablePath()
                path.move(to: NSPoint(x: p.x - 4, y: p.y + 2))
                path.addCurve(to: NSPoint(x: p.x + 4, y: p.y - 2), control1: NSPoint(x: p.x - 5, y: p.y - 5), control2: NSPoint(x: p.x + 1, y: p.y - 6))
                pencil(path, width: 0.8, opacity: fade * 0.5, part: .trail)
            } else {
                sketch([NSPoint(x: p.x, y: p.y), NSPoint(x: p.x + 1.6, y: p.y - 0.8)], seed: p.id, width: 0.7, opacity: fade * 0.62, part: .trail)
            }
        }
    }

    private static let puffOutline: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.8, y: 0.3))
        path.addCurve(to: CGPoint(x: 0.2, y: 0.8), control1: CGPoint(x: 0.8, y: 0.8), control2: CGPoint(x: 0.5, y: 1))
        path.addCurve(to: CGPoint(x: -0.7, y: 0.5), control1: CGPoint(x: -0.2, y: 1.1), control2: CGPoint(x: -0.8, y: 1))
        path.addCurve(to: CGPoint(x: -0.8, y: -0.4), control1: CGPoint(x: -1.2, y: 0.5), control2: CGPoint(x: -1.3, y: -0.3))
        path.addCurve(to: CGPoint(x: 0.1, y: -0.6), control1: CGPoint(x: -0.8, y: -1), control2: CGPoint(x: -0.1, y: -1.1))
        path.addCurve(to: CGPoint(x: 0.6, y: -0.1), control1: CGPoint(x: 0.7, y: -0.8), control2: CGPoint(x: 0.9, y: -0.2))
        path.addCurve(to: CGPoint(x: -0.15, y: 0.15), control1: CGPoint(x: 0.3, y: 0.3), control2: CGPoint(x: -0.4, y: -0.2))
        return path
    }()

    private func drawPuffs() {
        for puff in world.puffs {
            let progress = min(puff.age / puff.lifetime, 1)
            let radius = (5 + puff.strength * 10) * (0.55 + progress * 0.85)
            let opacity = min(puff.age / 0.05, 1) * (1 - progress) *
                (0.2 + puff.strength * 0.65) * min(puff.strength / 0.15, 1)
            var transform = CGAffineTransform(a: radius, b: 0, c: 0, d: radius * 0.72, tx: puff.x, ty: puff.y)
            if let cloud = Self.puffOutline.copy(using: &transform) {
                pencil(cloud, width: 0.75 + puff.strength * 0.25, opacity: opacity, part: .trail)
            }
            if progress < 0.35 {
                sketch([NSPoint(x: puff.x + radius + 2, y: puff.y - 1),
                        NSPoint(x: puff.x + radius + 5, y: puff.y - 2)],
                       seed: puff.id + 7_000, width: 0.65, opacity: opacity * 0.6, part: .trail)
            }
        }
    }

    private static let halo = CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)

    private func pencil(_ path: CGPath, width: Double, opacity: Double = 0.85, part: PencilPart = .scenery) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(Self.halo); context.setAlpha(opacity * 0.62)
        context.setLineWidth(width + 1.05); context.addPath(path); context.strokePath()
        context.setStrokeColor(inkColors[part]!); context.setAlpha(opacity)
        context.setLineWidth(width); context.addPath(path); context.strokePath()
        context.setAlpha(1)
    }

    private struct SketchShape { let vertices: [NSPoint]; let path: CGPath }
    private var sketchCache = [Int: SketchShape]()

    private func sketch(_ points: [NSPoint], seed: Int, width: Double, opacity: Double = 0.85, part: PencilPart = .scenery) {
        guard points.count > 1, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = points[0]
        let path: CGPath
        if let cached = sketchCache[seed], cached.vertices.count == points.count,
           points.indices.allSatisfy({ abs(points[$0].x - origin.x - cached.vertices[$0].x) < 1e-7 &&
                                       abs(points[$0].y - origin.y - cached.vertices[$0].y) < 1e-7 }) {
            path = cached.path
        } else {
            let vertices = points.map { NSPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            let line = CGMutablePath(); line.move(to: .zero)
            var index = 0
            for i in 1..<vertices.count {
                let a = vertices[i - 1], b = vertices[i]
                let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 7))
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let jitter = step == steps ? 0 : SoundFlightWorld.noise(index, seed) * 0.27
                    line.addLine(to: NSPoint(x: a.x + (b.x - a.x) * t + jitter,
                                            y: a.y + (b.y - a.y) * t + jitter * 0.7))
                    index += 1
                }
            }
            path = line
            // One current shape per seed, bounded even during very long sessions.
            if sketchCache.count >= 512 { sketchCache.removeAll(keepingCapacity: true) }
            sketchCache[seed] = SketchShape(vertices: vertices, path: path)
        }
        context.saveGState(); context.translateBy(x: origin.x, y: origin.y)
        pencil(path, width: width, opacity: opacity, part: part)
        context.restoreGState()
    }

    private struct TextKey: Hashable { let text: String; let size: Double }
    private struct PencilText {
        let outline: CTLine
        let ink: CTLine
        let width: Double
        let baseline: Double
    }
    private var textCache = [TextKey: PencilText]()

    private func textLayout(_ text: String, size: Double) -> PencilText {
        let key = TextKey(text: text, size: size)
        if let cached = textCache[key] { return cached }
        let font = NSFont(name: "Bradley Hand", size: size) ?? NSFont.systemFont(ofSize: size)
        let halo = NSColor(calibratedWhite: 0.98, alpha: 1)
        let outline = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: halo, .strokeWidth: -3, .strokeColor: halo]))
        let ink = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: palette.notes.nsColor]))
        let layout = PencilText(outline: outline, ink: ink,
                                width: CTLineGetTypographicBounds(ink, nil, nil, nil), baseline: font.ascender)
        // Scores change indefinitely; never retain the whole session's text.
        if textCache.count >= 64 { textCache.removeAll(keepingCapacity: true) }
        textCache[key] = layout
        return layout
    }

    private func drawText(_ text: String, at point: NSPoint, size: Double, opacity: Double) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = textLayout(text, size: size)
        context.saveGState()
        context.translateBy(x: point.x, y: point.y + layout.baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; context.textPosition = .zero
        context.setAlpha(min(0.6, opacity * 0.8)); CTLineDraw(layout.outline, context)
        context.textPosition = .zero
        context.setAlpha(opacity); CTLineDraw(layout.ink, context)
        context.restoreGState()
    }
}
