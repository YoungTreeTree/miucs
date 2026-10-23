import AppKit

/// Only vector drawing lives here. Audio consumption and animation stay in the core session.
@MainActor
final class StaffNoteView: NSView {
    private(set) var scene: StaffNoteScene
    var onRender: ((_ seconds: Double, _ timestamp: Double) -> Void)?
    private(set) var inkStyle = VisualizationAppearance.graphite
    private var ink = VisualizationAppearance.graphite.ink.cgColor
    private let halo = NSColor(calibratedWhite: 0.98, alpha: 0.8).cgColor
    private static let trailFade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1)] as CFArray,
        locations: [0, 1])!
    private static let staff: CGPath = {
        let path = CGMutablePath()
        for (i, y) in [58.0, 66, 74, 82, 90].enumerated() {
            path.move(to: CGPoint(x: 20, y: y))
            path.addCurve(to: CGPoint(x: 780, y: y),
                control1: CGPoint(x: 240, y: y + (i.isMultiple(of: 2) ? 0.14 : -0.14)),
                control2: CGPoint(x: 570, y: y - 0.12))
        }
        return path
    }()
    private static let clef: CGPath = {
        // The curl circles G4 (the second line from the bottom, y=82).
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 41, y: 86))
        p.addCurve(to: CGPoint(x: 36, y: 78), control1: CGPoint(x: 35, y: 87), control2: CGPoint(x: 31, y: 81))
        p.addCurve(to: CGPoint(x: 48, y: 83), control1: CGPoint(x: 42, y: 72), control2: CGPoint(x: 50, y: 77))
        p.addCurve(to: CGPoint(x: 29, y: 89), control1: CGPoint(x: 47, y: 95), control2: CGPoint(x: 30, y: 97))
        p.addCurve(to: CGPoint(x: 39, y: 61), control1: CGPoint(x: 19, y: 78), control2: CGPoint(x: 34, y: 67))
        p.addCurve(to: CGPoint(x: 41, y: 43), control1: CGPoint(x: 46, y: 54), control2: CGPoint(x: 45, y: 46))
        p.addCurve(to: CGPoint(x: 36, y: 63), control1: CGPoint(x: 32, y: 45), control2: CGPoint(x: 34, y: 56))
        p.addCurve(to: CGPoint(x: 44, y: 103), control1: CGPoint(x: 39, y: 79), control2: CGPoint(x: 43, y: 93))
        p.addCurve(to: CGPoint(x: 33, y: 108), control1: CGPoint(x: 47, y: 117), control2: CGPoint(x: 31, y: 115))
        p.addCurve(to: CGPoint(x: 36, y: 105), control1: CGPoint(x: 31, y: 104), control2: CGPoint(x: 34, y: 102))
        return p
    }()
    private var labels = [String: NSAttributedString]()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(preview: StaffNoteScene = StaffNoteScene()) {
        scene = preview
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Miucs · 五线谱音符")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func updatePreview(_ scene: StaffNoteScene) { self.scene = scene }
    func applyAppearance(_ appearance: VisualizationAppearance) {
        guard inkStyle != appearance else { return }
        inkStyle = appearance; ink = appearance.ink.cgColor
        labels.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = onRender == nil ? nil : ProcessInfo.processInfo.systemUptime
        defer { if let start { onRender?(ProcessInfo.processInfo.systemUptime - start, start) } }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        cg.scaleBy(x: bounds.width / 800, y: bounds.height / 160)
        cg.setLineCap(.round); cg.setLineJoin(.round)
        pencil(Self.staff, width: 0.72, opacity: 0.48, in: cg)
        pencil(Self.clef, width: 1.35, opacity: 0.8, in: cg)
        drawTrail(in: cg)
        drawLedgerLines(in: cg)
        // This pale, unscaled marker always indicates the exact notation position.
        if scene.pitch != nil {
            cg.saveGState(); cg.setAlpha(0.28 + 0.2 * scene.labelOpacity)
            cg.translateBy(x: StaffNoteScene.noteX, y: scene.targetY)
            let head = headPath()
            cg.addPath(head); cg.setFillColor(CGColor(gray: 0.96, alpha: 0.8)); cg.fillPath()
            pencil(head, width: 0.65, opacity: 0.6, in: cg)
            cg.restoreGState()
        }
        drawNote(in: cg)
        let labelY = min(139, max(5, scene.targetY - 8))
        if let pitch = scene.pitch {
            drawLabel(pitch.name, at: CGPoint(x: 664, y: labelY), opacity: scene.labelOpacity * 0.85, in: cg)
        }
        drawLabel("—", at: CGPoint(x: 664, y: labelY), opacity: (1 - scene.labelOpacity) * 0.4, in: cg)
    }

    private func drawLedgerLines(in cg: CGContext) {
        guard let pitch = scene.pitch else { return }
        let p = CGMutablePath()
        for y in pitch.ledgerYs {
            p.move(to: CGPoint(x: 630, y: y))
            p.addQuadCurve(to: CGPoint(x: 650, y: y), control: CGPoint(x: 640, y: y + 0.12))
        }
        pencil(p, width: 0.8, opacity: 0.35 + scene.labelOpacity * 0.35, in: cg)
    }
    private func drawTrail(in cg: CGContext) {
        guard !scene.trace.isEmpty else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        let area = CGRect(x: 80, y: 0, width: 560, height: 160)
        cg.clip(to: area); cg.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
        let path = CGMutablePath()
        var segment: Int?
        for point in scene.trace {
            let p = CGPoint(x: scene.traceX(point), y: point.y)
            if segment != point.segment {
                path.move(to: p); path.addLine(to: CGPoint(x: p.x + 0.3, y: p.y))
            } else { path.addLine(to: p) }
            segment = point.segment
        }
        pencil(path, width: 1.05, opacity: 0.52, in: cg)
        cg.setBlendMode(.destinationIn)
        cg.drawLinearGradient(Self.trailFade, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 640, y: 0),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.endTransparencyLayer()
    }
    private func headPath() -> CGPath {
        var t = CGAffineTransform(rotationAngle: -0.32)
        return CGPath(ellipseIn: CGRect(x: -5.7, y: -3.8, width: 11.4, height: 7.6), transform: &t)
    }
    private func drawNote(in cg: CGContext) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.setAlpha(scene.opacity)
        cg.translateBy(x: StaffNoteScene.noteX, y: scene.noteY)
        cg.scaleBy(x: scene.scale, y: scene.scale)
        let head = headPath(), stem = CGMutablePath()
        let down = scene.baseY < StaffPitch.middleY
        let x = down ? -4.8 : 4.8, tip = down ? 26.0 : -26.0
        stem.move(to: CGPoint(x: x, y: 0))
        stem.addQuadCurve(to: CGPoint(x: x + 0.12, y: tip), control: CGPoint(x: x - 0.14, y: tip / 2))
        // A single flag keeps the character an eighth note at every pitch.
        stem.move(to: CGPoint(x: x, y: tip))
        stem.addCurve(to: CGPoint(x: x + 8, y: tip + (down ? -10 : 11)),
            control1: CGPoint(x: x + 3, y: tip + (down ? -4 : 4)),
            control2: CGPoint(x: x + 11, y: tip + (down ? -2 : 7)))
        stem.addQuadCurve(to: CGPoint(x: x + 6, y: tip + (down ? -17 : 18)),
            control: CGPoint(x: x + 9, y: tip + (down ? -14 : 15)))
        pencil(stem, width: 1.35, opacity: 1, in: cg)
        pencil(head, width: 1.5, opacity: 1, in: cg)
        cg.addPath(head); cg.setFillColor(ink); cg.fillPath()
        let hatch = CGMutablePath()
        for i in 0..<4 {
            let x = -3.8 + Double(i) * 2
            hatch.move(to: CGPoint(x: x, y: 1.5)); hatch.addLine(to: CGPoint(x: x + 1.4, y: -1.6))
        }
        cg.addPath(hatch); cg.setStrokeColor(CGColor(gray: 0.8, alpha: 0.22)); cg.setLineWidth(0.35); cg.strokePath()
        if scene.pitch?.isSharp == true {
            let sharp = CGMutablePath()
            for x in [-17.0, -13.4] {
                sharp.move(to: CGPoint(x: x, y: -7)); sharp.addLine(to: CGPoint(x: x - 0.5, y: 7))
            }
            for y in [-2.8, 2.8] {
                sharp.move(to: CGPoint(x: -20, y: y + 1)); sharp.addLine(to: CGPoint(x: -10.6, y: y - 1))
            }
            pencil(sharp, width: 1, opacity: 0.9, in: cg)
        }
    }
    private func pencil(_ path: CGPath, width: Double, opacity: Double, in cg: CGContext) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.addPath(path); cg.setStrokeColor(halo.copy(alpha: opacity * 0.8)!); cg.setLineWidth(width + 1.25); cg.strokePath()
        cg.addPath(path); cg.setStrokeColor(ink.copy(alpha: opacity)!); cg.setLineWidth(width); cg.strokePath()
    }
    private func drawLabel(_ text: String, at point: CGPoint, opacity: Double, in cg: CGContext) {
        guard opacity > 0.001 else { return }
        if labels[text] == nil {
            labels[text] = NSAttributedString(string: text, attributes: [
                .font: NSFont(name: "Bradley Hand", size: 14) ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(cgColor: ink)!,
                .strokeColor: NSColor(calibratedWhite: 0.98, alpha: 0.9), .strokeWidth: -2.0])
        }
        cg.saveGState(); cg.setAlpha(opacity); labels[text]!.draw(at: point); cg.restoreGState()
    }
}
