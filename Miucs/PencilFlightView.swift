import AppKit
import Combine

@MainActor
final class PencilFlightView: NSView {
    private(set) var world = SoundFlightWorld()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastTick = 0.0
    private var audioStatus = ""
    private var connected = false
    private var resizeStartFrame: NSRect?
    private var resizeStartMouse = NSPoint.zero
    var adjustingPosition = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(engine: AudioEngine) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        engine.$features.sink { [weak self] in self?.world.receive(audio: $0) }.store(in: &subscriptions)
        engine.$melody.sink { [weak self] frame in
            guard let self else { return }
            self.world.receive(melody: frame)
        }.store(in: &subscriptions)
        engine.$status.sink { [weak self] in self?.audioStatus = $0; self?.needsDisplay = true }.store(in: &subscriptions)
        engine.$isRunning.sink { [weak self] in self?.connected = $0; self?.needsDisplay = true }.store(in: &subscriptions)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Miucs 铅笔飞鸟，随系统音乐自动飞行")
    }

    init(preview: SoundFlightWorld) {
        world = preview; connected = true
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRendering(_ active: Bool) {
        timer?.invalidate(); timer = nil
        guard active else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let wasMoving = world.activity > 0 || !world.particles.isEmpty || world.flap > 0.001 || world.needsMotionUpdates
        world.advance(seconds: min(now - lastTick, 0.1)); lastTick = now
        if wasMoving || world.activity > 0 || !world.particles.isEmpty || world.needsMotionUpdates {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard adjustingPosition, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.maxX - 30 && point.y >= bounds.maxY - 30 {
            resizeStartFrame = window.frame
            resizeStartMouse = NSEvent.mouseLocation
        } else { window.performDrag(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard adjustingPosition, let initial = resizeStartFrame,
              let panel = window as? VisualizerPanel else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - resizeStartMouse.x, dy = resizeStartMouse.y - mouse.y
        let ratio = 260.0 / 400
        let deltaWidth = (dx + dy * ratio) / (1 + ratio * ratio)
        panel.setDrawingWidth(initial.width + deltaWidth, topLeft: NSPoint(x: initial.minX, y: initial.maxY), persist: false)
    }

    override func mouseUp(with event: NSEvent) {
        if resizeStartFrame != nil { (window as? VisualizerPanel)?.saveDrawingFrame() }
        resizeStartFrame = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let scale = NSAffineTransform()
        scale.scaleX(by: bounds.width / 400, yBy: bounds.height / 260); scale.concat()
        drawEnvironment()
        for gate in world.gates { draw(gate: gate) }
        drawParticles()
        drawBird()
        drawMelodyNote()
        drawText(String(world.score), at: NSPoint(x: 354, y: 9), size: 21, opacity: 0.75)
        if adjustingPosition {
            drawText("拖动移动 · 右下角缩放 · 菜单栏完成", at: NSPoint(x: 47, y: 235), size: 12, opacity: 0.95)
            for i in 0..<3 {
                let inset = Double(i) * 4
                sketch([NSPoint(x: 374 + inset, y: 253), NSPoint(x: 390, y: 237 + inset)],
                       seed: 1900 + i, width: 1, opacity: 0.75)
            }
        } else if !connected {
            let text = audioStatus.hasPrefix("正在连接") ? "正在连接声音…" : "音频未连接 · 从菜单栏重新连接"
            drawText(text, at: NSPoint(x: 75, y: 235), size: 12, opacity: 0.9)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEnvironment() {
        let backgroundWeight = 0.85 - world.brightness * 0.22
        for i in 0..<3 {
            let x = (Double(i) * 171 + 38 - world.distance * (0.10 + Double(i) * 0.025)).truncatingRemainder(dividingBy: 510)
            let position = x < -65 ? x + 510 : x
            let y = 34 + Double(i % 2) * 38
            let cloud = NSBezierPath()
            cloud.move(to: NSPoint(x: position - 24, y: y + 9))
            cloud.curve(to: NSPoint(x: position - 14, y: y - 1), controlPoint1: NSPoint(x: position - 27, y: y + 1), controlPoint2: NSPoint(x: position - 20, y: y - 5))
            cloud.curve(to: NSPoint(x: position + 9, y: y - 4), controlPoint1: NSPoint(x: position - 13, y: y - 18), controlPoint2: NSPoint(x: position + 8, y: y - 19))
            cloud.curve(to: NSPoint(x: position + 25, y: y + 9), controlPoint1: NSPoint(x: position + 23, y: y - 11), controlPoint2: NSPoint(x: position + 31, y: y + 2))
            cloud.curve(to: NSPoint(x: position - 24, y: y + 9), controlPoint1: NSPoint(x: position + 5, y: y + 12), controlPoint2: NSPoint(x: position - 10, y: y + 7))
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

    private func draw(gate: FlightGate) {
        let x = SoundFlightWorld.birdScreenX + gate.x - world.distance
        guard x > -40, x < 440 else { return }
        let pressure = 1.15 + world.bass * 0.5
        let pulse = world.bass * world.flap
        let halfBody = 17 + pulse * 1.5
        let halfCap = 24 + pulse * 2 // Always inside the reserved halfWidth = 30.
        let upper = gate.openingTop, lower = gate.openingBottom
        let ink = gate.passed ? 0.64 : 0.87
        for side in [-1.0, 1.0] {
            sketch([NSPoint(x: x + side * halfBody, y: -3), NSPoint(x: x + side * halfBody, y: upper - 9)], seed: gate.id * 11 + Int(side) + 1000, width: pressure, opacity: ink)
            sketch([NSPoint(x: x + side * halfBody, y: lower + 9), NSPoint(x: x + side * halfBody, y: 246)], seed: gate.id * 11 + Int(side) + 1100, width: pressure, opacity: ink)
        }
        for (side, pair) in [(upper, -1.0), (lower, 1.0)].enumerated() {
            let (edge, direction) = pair
            sketch([NSPoint(x: x - halfCap, y: edge + direction * 9), NSPoint(x: x - halfCap, y: edge), NSPoint(x: x + halfCap, y: edge), NSPoint(x: x + halfCap, y: edge + direction * 9), NSPoint(x: x - halfCap, y: edge + direction * 9)], seed: gate.id * 17 + side + 1700, width: pressure, opacity: ink)
            for h in 0..<4 {
                let hx = x - halfCap + 5 + Double(h) * 5
                sketch([NSPoint(x: hx, y: edge + direction * 2), NSPoint(x: hx + 3, y: edge + direction * 6)], seed: gate.id + h + 1500, width: 0.7, opacity: 0.35 + world.bass * 0.13)
            }
        }
        for h in 0..<3 {
            let y = upper - 18 - Double(h) * 8
            if y > 5 {
                sketch([NSPoint(x: x + halfBody - 6, y: y), NSPoint(x: x + halfBody - 2, y: y - 3)], seed: gate.id * 3 + h, width: 0.6, opacity: 0.24)
            }
        }
    }

    private func drawMelodyNote() {
        let note = world.melodyNoteName ?? "—"
        let size = 17.0
        let font = NSFont(name: "Bradley Hand", size: size) ?? NSFont.systemFont(ofSize: size)
        let width = (note as NSString).size(withAttributes: [.font: font]).width
        // Trail the bird without rotating with it, leaving its tail silhouette clear.
        drawText(note, at: NSPoint(x: max(6, SoundFlightWorld.birdScreenX - 35 - width),
                                  y: world.birdY - 12),
                 size: size, opacity: world.melodyNoteOpacity)
    }

    private func drawBird() {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: SoundFlightWorld.birdScreenX, yBy: world.birdY)
        transform.rotate(byRadians: world.birdAngle)
        let stretch = 1 + world.flap * world.loudness * 0.06
        transform.scaleX(by: 1 / stretch, yBy: stretch)
        transform.concat()
        let body = NSBezierPath()
        body.move(to: NSPoint(x: -15, y: 0))
        body.curve(to: NSPoint(x: 7, y: -10), controlPoint1: NSPoint(x: -14, y: -14), controlPoint2: NSPoint(x: 0, y: -15))
        body.curve(to: NSPoint(x: 15, y: 1), controlPoint1: NSPoint(x: 14, y: -9), controlPoint2: NSPoint(x: 15, y: -4))
        body.curve(to: NSPoint(x: -15, y: 0), controlPoint1: NSPoint(x: 16, y: 15), controlPoint2: NSPoint(x: -14, y: 17))
        pencil(body, width: 1.55, opacity: 0.96)
        sketch([NSPoint(x: 14, y: -1), NSPoint(x: 23, y: 2), NSPoint(x: 14, y: 5)], seed: 31, width: 1.35)
        sketch([NSPoint(x: -14, y: 2), NSPoint(x: -23, y: -1), NSPoint(x: -18, y: 7), NSPoint(x: -12, y: 8)], seed: 32, width: 1.3)
        let eye = NSBezierPath(ovalIn: NSRect(x: 7, y: -5, width: 2.8, height: 3.1))
        NSColor(calibratedWhite: 0.98, alpha: 0.7).setStroke(); eye.lineWidth = 1; eye.stroke()
        NSColor(calibratedWhite: 0.19, alpha: 0.98).setFill(); eye.fill()
        let wing = NSBezierPath()
        let lift = world.flap * (10 + world.loudness * 9)
        wing.move(to: NSPoint(x: -7, y: 3))
        wing.curve(to: NSPoint(x: 1, y: 7 - lift), controlPoint1: NSPoint(x: -15, y: 6 - lift), controlPoint2: NSPoint(x: -9, y: 17 - lift))
        pencil(wing, width: 1.4, opacity: 0.94)
        if world.flap > 0.35 {
            sketch([NSPoint(x: -13, y: -5 - lift * 0.35), NSPoint(x: -17, y: -8 - lift * 0.45)], seed: 42, width: 0.7, opacity: world.flap * 0.45)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawParticles() {
        for p in world.particles {
            let fade = max(p.life / p.lifetime, 0)
            if p.feather {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: p.x - 4, y: p.y + 2))
                path.curve(to: NSPoint(x: p.x + 4, y: p.y - 2), controlPoint1: NSPoint(x: p.x - 5, y: p.y - 5), controlPoint2: NSPoint(x: p.x + 1, y: p.y - 6))
                pencil(path, width: 0.8, opacity: fade * 0.5)
            } else {
                sketch([NSPoint(x: p.x, y: p.y), NSPoint(x: p.x + 1.6, y: p.y - 0.8)], seed: p.id, width: 0.7, opacity: fade * 0.62)
            }
        }
    }

    private func pencil(_ path: NSBezierPath, width: Double, opacity: Double = 0.85) {
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor(calibratedWhite: 0.98, alpha: opacity * 0.62).setStroke()
        path.lineWidth = width + 1.05; path.stroke()
        NSColor(calibratedRed: 0.24, green: 0.235, blue: 0.22, alpha: opacity).setStroke()
        path.lineWidth = width; path.stroke()
    }

    private func sketch(_ points: [NSPoint], seed: Int, width: Double, opacity: Double = 0.85) {
        guard points.count > 1 else { return }
        let path = NSBezierPath(); path.move(to: points[0])
        var index = 0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 7))
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                let jitter = s == steps ? 0 : SoundFlightWorld.noise(index, seed) * 0.27
                path.line(to: NSPoint(x: a.x + (b.x - a.x) * t + jitter,
                                     y: a.y + (b.y - a.y) * t + jitter * 0.7))
                index += 1
            }
        }
        pencil(path, width: width, opacity: opacity)
    }

    private func drawText(_ text: String, at point: NSPoint, size: Double, opacity: Double) {
        let font = NSFont(name: "Bradley Hand", size: size) ?? NSFont.systemFont(ofSize: size)
        let halo = NSColor(calibratedWhite: 0.98, alpha: min(0.6, opacity * 0.8))
        let outline: [NSAttributedString.Key: Any] = [.font: font,
            .foregroundColor: halo, .strokeWidth: -3, .strokeColor: halo]
        NSAttributedString(string: text, attributes: outline).draw(at: point)
        NSAttributedString(string: text, attributes: [.font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.24, alpha: opacity)]).draw(at: point)
    }
}
