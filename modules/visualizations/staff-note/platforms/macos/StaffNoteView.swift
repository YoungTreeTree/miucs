import AppKit
import CoreText
import QuartzCore

/// Only vector drawing lives here. Audio consumption and animation stay in the core session.
@MainActor
final class StaffNoteView: NSView {
    private(set) var scene: StaffNoteScene
    private(set) var stars = [StaffStar]()
    private(set) var rings = [StaffBeatRing]()
    var onRender: ((_ seconds: Double, _ timestamp: Double) -> Void)?
    private(set) var inkStyle = VisualizationAppearance.graphite
    private var ink = VisualizationAppearance.graphite.ink.cgColor
    private let halo = NSColor(calibratedWhite: 0.98, alpha: 0.8).cgColor
    private static let trailFade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1)] as CFArray,
        locations: [0, 1])!
    private static let beatFadeColors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1),
                                        CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)]
    private static let beatFade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: beatFadeColors as CFArray, locations: [0, 0.05, 0.95, 1])!
    private static let beatHaloWidth = 0.85
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
    private static let labelFont = NSFont(name: "Bradley Hand", size: 14) ?? NSFont.systemFont(ofSize: 14)
    private static let noteHead: CGPath = {
        var transform = CGAffineTransform(rotationAngle: -0.32)
        return CGPath(ellipseIn: CGRect(x: -5.7, y: -3.8, width: 11.4, height: 7.6), transform: &transform)
    }()
    private static let upStem = stemPath(down: false)
    private static let downStem = stemPath(down: true)
    // Three cached opacity bands soften arc tips without rebuilding paths each frame.
    private static let beatTapers = [0.48, 0.78, 1.0]
    private static let beatMainArcs = beatPaths([(0.05, 1.30), (1.88, 3.57), (4.15, 5.72)])
    private static let beatSatelliteArcs = beatPaths([(-0.65, 1.55)])
    private static func beatPaths(_ arcs: [(Double, Double)]) -> [CGPath] {
        (0..<3).map { band in
            let path = CGMutablePath()
            let ranges: [[(Double, Double)]] = [[(0, 0.07), (0.93, 1)], [(0.07, 0.22), (0.78, 0.93)], [(0.22, 0.78)]]
            for (start, end) in arcs {
                for (lo, hi) in ranges[band] {
                    for step in 0...24 {
                        let angle = start + (end - start) * (lo + (hi - lo) * Double(step) / 24)
                        let radius = 10 * (1 + 0.016 * sin(angle * 3))
                        let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
            }
            return path.copy()!
        }
    }
    private static func beatPaths(for ring: StaffBeatRing) -> [CGPath] {
        ring.arc == .main ? beatMainArcs : beatSatelliteArcs
    }
    private static func beatTransform(_ ring: StaffBeatRing) -> CGAffineTransform {
        CGAffineTransform(scaleX: ring.radius / 10, y: ring.radius / 10 * 0.9).rotated(by: ring.rotation)
    }
    private static let star: CGPath = {
        let path = CGMutablePath()
        for i in 0..<10 {
            let angle = -.pi / 2 + Double(i) * .pi / 5
            let radius = i.isMultiple(of: 2) ? 5.0 : 2.1
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath(); return path.copy()!
    }()
    private static let hatch: CGPath = {
        let path = CGMutablePath()
        for i in 0..<4 {
            let x = -3.8 + Double(i) * 2
            path.move(to: CGPoint(x: x, y: 1.5)); path.addLine(to: CGPoint(x: x + 1.4, y: -1.6))
        }
        return path
    }()
    private static let sharp: CGPath = {
        let path = CGMutablePath()
        for x in [-17.0, -13.4] {
            path.move(to: CGPoint(x: x, y: -7)); path.addLine(to: CGPoint(x: x - 0.5, y: 7))
        }
        for y in [-2.8, 2.8] {
            path.move(to: CGPoint(x: -20, y: y + 1)); path.addLine(to: CGPoint(x: -10.6, y: y - 1))
        }
        return path
    }()
    private var labels = [String: CTLine]()
    private var attributedLabels = [String: NSAttributedString]()
    private var retainedDrawing: RetainedDrawing?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    init(preview: StaffNoteScene = StaffNoteScene()) {
        scene = preview
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Miucs · 五线谱音符")
        prepareLabels()
        // Prepare fixed geometry before the first animated frame.
        _ = Self.noteHead; _ = Self.upStem; _ = Self.downStem
        _ = Self.hatch; _ = Self.sharp; _ = Self.star; _ = Self.beatMainArcs; _ = Self.beatSatelliteArcs; _ = Self.beatFade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func updatePreview(_ scene: StaffNoteScene, stars: [StaffStar] = [], rings: [StaffBeatRing] = []) {
        self.scene = scene; self.stars = stars; self.rings = rings
    }
    func applyAppearance(_ appearance: VisualizationAppearance) {
        guard inkStyle != appearance else { return }
        inkStyle = appearance; ink = appearance.ink.cgColor
        prepareLabels()
        needsDisplay = true
    }

    override func updateLayer() {
        let start = onRender == nil ? nil : ProcessInfo.processInfo.systemUptime
        defer { if let start { onRender?(ProcessInfo.processInfo.systemUptime - start, start) } }
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if retainedDrawing == nil {
            let drawing = RetainedDrawing()
            layer.addSublayer(drawing.root); retainedDrawing = drawing
        }
        retainedDrawing!.update(scene: scene, stars: stars, rings: rings, size: bounds.size, ink: ink, labels: attributedLabels,
                                backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
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
        drawStars(in: cg)
        drawBeatRings(in: cg)
        // This pale, unscaled marker always indicates the exact notation position.
        if scene.pitch != nil {
            cg.saveGState(); cg.setAlpha(0.28 + 0.2 * scene.labelOpacity)
            cg.translateBy(x: StaffNoteScene.noteX, y: scene.targetY)
            let head = Self.noteHead
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

    private func drawStars(in cg: CGContext) {
        for star in stars.prefix(StaffKeyboardStars.starLimit) {
            cg.saveGState()
            cg.translateBy(x: star.x, y: star.y); cg.rotate(by: star.rotation)
            cg.scaleBy(x: star.radius / 5, y: star.radius / 5)
            pencil(Self.star, width: 0.85, opacity: star.opacity, in: cg)
            cg.restoreGState()
        }
    }
    private func drawTrail(in cg: CGContext) {
        guard !scene.trace.isEmpty else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        let area = CGRect(x: 80, y: 0, width: 560, height: 160)
        cg.clip(to: area); cg.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
        pencil(Self.tracePath(scene), width: 1.05, opacity: 0.52, in: cg)
        cg.setBlendMode(.destinationIn)
        cg.drawLinearGradient(Self.trailFade, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 640, y: 0),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.endTransparencyLayer()
    }
    private static func tracePath(_ scene: StaffNoteScene, originX: Double = 0) -> CGPath {
        let path = CGMutablePath()
        var segment: Int?
        var previous: CGPoint?
        let liveTail = scene.hasContinuousTraceTail ? scene.trace.last : nil
        let headOffset = liveTail.map { scene.noteY - $0.y } ?? 0
        for point in scene.trace {
            let x = scene.traceX(point)
            var y = point.y
            if point.segment == liveTail?.segment {
                // Join the moving head smoothly; accepted history itself keeps its true pitch.
                let blend = max(0, min(1, 1 - (StaffNoteScene.noteX - x) / 10))
                y += headOffset * blend * blend * (3 - 2 * blend)
            }
            let p = CGPoint(x: x - originX, y: y)
            if segment != point.segment { path.move(to: p) }
            else if let join = point.join, let previous {
                appendTraceJoin(from: previous, to: p, progress: join.progress(at: scene.elapsed), in: path)
            } else { path.addLine(to: p) }
            segment = point.segment
            previous = p
        }
        // The audible phrase stays connected through filtering, without inventing pitch samples.
        if liveTail != nil {
            path.addLine(to: CGPoint(x: StaffNoteScene.noteX - originX, y: scene.noteY))
        }
        return path
    }
    /// Reveal a missing interval from both real endpoints; the same curve remains once joined.
    private static func appendTraceJoin(from start: CGPoint, to end: CGPoint, progress: Double, in path: CGMutablePath) {
        let handle = (end.x - start.x) * 0.45
        let c1 = CGPoint(x: start.x + handle, y: start.y), c2 = CGPoint(x: end.x - handle, y: end.y)
        if progress >= 1 {
            path.addCurve(to: end, control1: c1, control2: c2); return
        }
        guard progress > 0 else { path.move(to: end); return }
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        // De Casteljau subdivision keeps both tips on the final curve, without changing history.
        let t = progress / 2, s = 1 - t
        let left1 = mix(start, c1, t), left2 = mix(left1, mix(c1, c2, t), t)
        let leftEnd = mix(left2, mix(mix(c1, c2, t), mix(c2, end, t), t), t)
        path.addCurve(to: leftEnd, control1: left1, control2: left2)
        let right2 = mix(c2, end, s), right1 = mix(mix(c1, c2, s), right2, s)
        let rightStart = mix(mix(mix(start, c1, s), mix(c1, c2, s), s), right1, s)
        path.move(to: rightStart)
        path.addCurve(to: end, control1: right1, control2: right2)
    }
    private static func stemPath(down: Bool) -> CGPath {
        let stem = CGMutablePath()
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
        return stem
    }
    private func drawNote(in cg: CGContext) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.setAlpha(scene.opacity)
        cg.translateBy(x: scene.noteCenterX, y: scene.noteY)
        cg.scaleBy(x: scene.scale, y: scene.scale)
        let head = Self.noteHead, stem = scene.noteY < StaffPitch.middleY ? Self.downStem : Self.upStem
        // Tilt the stem and flag around the solid head's center; notation and head stay anchored.
        cg.saveGState()
        cg.rotate(by: scene.swayAngle)
        pencil(stem, width: 1.35, opacity: 1, in: cg)
        cg.restoreGState()
        pencil(head, width: 1.5, opacity: 1, in: cg)
        cg.addPath(head); cg.setFillColor(ink); cg.fillPath()
        cg.addPath(Self.hatch); cg.setStrokeColor(CGColor(gray: 0.8, alpha: 0.22)); cg.setLineWidth(0.35); cg.strokePath()
        if scene.pitch?.isSharp == true {
            pencil(Self.sharp, width: 1, opacity: 0.9, in: cg)
        }
    }
    private func drawBeatRings(in cg: CGContext) {
        guard !rings.isEmpty else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        cg.clip(to: CGRect(x: 0, y: 0, width: 800, height: 160))
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        for ring in rings.prefix(StaffBeatRings.limit) {
            cg.saveGState()
            cg.translateBy(x: ring.x, y: ring.y)
            let scale = ring.radius / 10
            cg.concatenate(Self.beatTransform(ring))
            cg.setLineCap(.round); cg.setLineJoin(.round)
            for (band, path) in Self.beatPaths(for: ring).enumerated() {
                pencil(path, width: ring.lineWidth / scale, opacity: ring.opacity * Self.beatTapers[band],
                       haloWidth: Self.beatHaloWidth / scale, in: cg)
            }
            cg.restoreGState()
        }
        cg.setBlendMode(.destinationIn)
        cg.drawLinearGradient(Self.beatFade, start: .zero, end: CGPoint(x: 0, y: 160), options: [])
        cg.endTransparencyLayer()
    }
    private func pencil(_ path: CGPath, width: Double, opacity: Double, haloWidth: Double = 1.25, in cg: CGContext) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.addPath(path); cg.setStrokeColor(halo.copy(alpha: opacity * 0.8)!); cg.setLineWidth(width + haloWidth); cg.strokePath()
        cg.addPath(path); cg.setStrokeColor(ink.copy(alpha: opacity)!); cg.setLineWidth(width); cg.strokePath()
    }
    private func prepareLabels() {
        labels.removeAll(keepingCapacity: true)
        attributedLabels.removeAll(keepingCapacity: true)
        let names = StaffPitch.supportedMIDI.map { StaffPitch(midi: $0)!.name } + ["—"]
        for name in names {
            let string = NSAttributedString(string: name, attributes: [
                .font: Self.labelFont,
                .foregroundColor: NSColor(cgColor: ink)!,
                .strokeColor: NSColor(calibratedWhite: 0.98, alpha: 0.9), .strokeWidth: -2.0])
            labels[name] = CTLineCreateWithAttributedString(string)
            attributedLabels[name] = string
        }
        retainedDrawing?.invalidateAppearance()
    }
    private func drawLabel(_ text: String, at point: CGPoint, opacity: Double, in cg: CGContext) {
        guard opacity > 0.001, let line = labels[text] else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        cg.setAlpha(opacity)
        cg.translateBy(x: point.x, y: point.y + Self.labelFont.ascender)
        cg.scaleBy(x: 1, y: -1)
        cg.textMatrix = .identity; cg.textPosition = .zero
        CTLineDraw(line, cg)
    }

    /// The native window submits vector paths and transforms, avoiding a full backing bitmap each frame.
    /// draw(_:) remains the vector reference for offline exports and pixel verification.
    @MainActor
    private final class RetainedDrawing {
        let root = CALayer()
        private let note = CALayer(), stem = CALayer(), marker = CALayer(), trail = CALayer()
        private let markerFill = CAShapeLayer(), headFill = CAShapeLayer(), hatch = CAShapeLayer()
        private let label = CATextLayer(), placeholder = CATextLayer()
        private var pairs = [PencilPair]()
        private var history: PencilPair!, markerStroke: PencilPair!
        private var headStroke: PencilPair!, stemStroke: PencilPair!, sharp: PencilPair!
        private var currentInk: CGColor?
        private var currentLabel: String?
        private var starPool = [(layer: CALayer, stroke: PencilPair)]()
        private var visibleStars = 0
        private var ringPool = [(layer: CALayer, strokes: [PencilPair])]()

        init() {
            root.bounds = CGRect(x: 0, y: 0, width: 800, height: 160)
            root.anchorPoint = .zero; root.position = .zero; root.isGeometryFlipped = false
            _ = pencil(StaffNoteView.staff, width: 0.72, opacity: 0.48, in: root)
            _ = pencil(StaffNoteView.clef, width: 1.35, opacity: 0.8, in: root)

            trail.name = "melody-trail"
            trail.bounds = CGRect(x: 0, y: 0, width: 560, height: 160)
            trail.position = CGPoint(x: 360, y: 80); trail.isGeometryFlipped = false
            trail.masksToBounds = true; root.addSublayer(trail)
            let fade = CAGradientLayer()
            fade.frame = trail.bounds
            fade.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1)]
            fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
            trail.mask = fade
            history = pencil(nil, width: 1.05, opacity: 0.52, in: trail)
            let stars = CALayer()
            stars.name = "keyboard-stars"; stars.bounds = root.bounds
            stars.position = CGPoint(x: 400, y: 80); stars.isGeometryFlipped = false
            root.addSublayer(stars)
            for _ in 0..<StaffKeyboardStars.starLimit {
                let layer = CALayer()
                layer.bounds = CGRect(x: -10, y: -10, width: 20, height: 20)
                layer.isGeometryFlipped = false; layer.isHidden = true
                stars.addSublayer(layer)
                starPool.append((layer, pencil(StaffNoteView.star, width: 0.85, opacity: 1, in: layer)))
            }
            let rings = CALayer()
            rings.name = "beat-rings"; rings.bounds = root.bounds
            rings.position = CGPoint(x: 400, y: 80); rings.isGeometryFlipped = false
            rings.masksToBounds = true
            let ringFade = CAGradientLayer()
            ringFade.frame = rings.bounds; ringFade.colors = StaffNoteView.beatFadeColors
            ringFade.locations = [0, 0.05, 0.95, 1]
            ringFade.startPoint = CGPoint(x: 0.5, y: 0); ringFade.endPoint = CGPoint(x: 0.5, y: 1)
            rings.mask = ringFade
            root.addSublayer(rings)
            for _ in 0..<StaffBeatRings.limit {
                let layer = CALayer()
                layer.bounds = CGRect(x: -16, y: -16, width: 32, height: 32)
                layer.isGeometryFlipped = false; layer.isHidden = true
                rings.addSublayer(layer)
                ringPool.append((layer, StaffNoteView.beatMainArcs.map { pencil($0, width: 0.65, opacity: 1, in: layer) }))
            }
            marker.bounds = CGRect(x: -8, y: -6, width: 16, height: 12)
            marker.name = "pitch-marker"
            marker.isGeometryFlipped = false; root.addSublayer(marker)
            configure(markerFill, in: marker)
            markerFill.path = StaffNoteView.noteHead; markerFill.fillColor = CGColor(gray: 0.96, alpha: 0.8)
            markerStroke = pencil(StaffNoteView.noteHead, width: 0.65, opacity: 0.6, in: marker)

            note.bounds = CGRect(x: -40, y: -50, width: 80, height: 100)
            note.name = "music-note"; note.isGeometryFlipped = false; root.addSublayer(note)
            stem.bounds = note.bounds; stem.position = .zero; stem.isGeometryFlipped = false
            note.addSublayer(stem)
            stemStroke = pencil(StaffNoteView.upStem, width: 1.35, opacity: 1, in: stem)
            headStroke = pencil(StaffNoteView.noteHead, width: 1.5, opacity: 1, in: note)
            configure(headFill, in: note); headFill.path = StaffNoteView.noteHead
            configure(hatch, in: note); hatch.path = StaffNoteView.hatch
            hatch.fillColor = nil; hatch.strokeColor = CGColor(gray: 0.8, alpha: 0.22); hatch.lineWidth = 0.35
            sharp = pencil(StaffNoteView.sharp, width: 1, opacity: 0.9, in: note)

            label.name = "pitch-label"
            for text in [label, placeholder] {
                text.bounds = CGRect(x: 0, y: 0, width: 80, height: 22)
                text.anchorPoint = .zero; text.isGeometryFlipped = false
                text.alignmentMode = .left; text.isWrapped = false
                root.addSublayer(text)
            }
        }

        func invalidateAppearance() { currentInk = nil; currentLabel = nil }

        func update(scene: StaffNoteScene, stars: [StaffStar], rings: [StaffBeatRing], size: CGSize, ink: CGColor,
                    labels: [String: NSAttributedString], backingScale: CGFloat) {
            root.setAffineTransform(CGAffineTransform(scaleX: size.width / 800, y: size.height / 160))
            if currentInk != ink {
                for pair in pairs { pair.ink.strokeColor = ink }
                headFill.fillColor = ink; currentInk = ink; currentLabel = nil
                placeholder.string = labels["—"]
            }
            let count = min(stars.count, starPool.count)
            for i in 0..<count {
                let star = stars[i], item = starPool[i]
                item.layer.isHidden = false
                item.layer.position = CGPoint(x: star.x, y: star.y)
                item.layer.setAffineTransform(CGAffineTransform(rotationAngle: star.rotation)
                    .scaledBy(x: star.radius / 5, y: star.radius / 5))
                item.stroke.setOpacity(star.opacity)
            }
            if count < visibleStars {
                for i in count..<visibleStars { starPool[i].layer.isHidden = true }
            }
            visibleStars = count
            for (i, item) in ringPool.enumerated() {
                item.layer.isHidden = i >= rings.count
                guard i < rings.count else { continue }
                let ring = rings[i], scale = ring.radius / 10
                item.layer.position = CGPoint(x: ring.x, y: ring.y)
                item.layer.setAffineTransform(StaffNoteView.beatTransform(ring))
                let paths = StaffNoteView.beatPaths(for: ring)
                for (band, stroke) in item.strokes.enumerated() {
                    stroke.setPath(paths[band])
                    stroke.setLineWidth(ring.lineWidth / scale, haloWidth: StaffNoteView.beatHaloWidth / scale)
                    stroke.setOpacity(ring.opacity * StaffNoteView.beatTapers[band])
                }
            }
            history.setPath(StaffNoteView.tracePath(scene, originX: 80))
            marker.position = CGPoint(x: StaffNoteScene.noteX, y: scene.targetY)
            marker.isHidden = scene.pitch == nil
            let markerOpacity = 0.28 + 0.2 * scene.labelOpacity
            markerFill.opacity = Float(markerOpacity); markerStroke.setOpacity(0.6 * markerOpacity)

            note.position = CGPoint(x: scene.noteCenterX, y: scene.noteY)
            note.setAffineTransform(CGAffineTransform(scaleX: scene.scale, y: scene.scale))
            stem.setAffineTransform(CGAffineTransform(rotationAngle: scene.swayAngle))
            stemStroke.setPath(scene.noteY < StaffPitch.middleY ? StaffNoteView.downStem : StaffNoteView.upStem)
            stemStroke.setOpacity(scene.opacity); headStroke.setOpacity(scene.opacity)
            headFill.opacity = Float(scene.opacity); hatch.opacity = Float(scene.opacity)
            sharp.setOpacity(scene.pitch?.isSharp == true ? scene.opacity * 0.9 : 0)

            let name = scene.pitch?.name
            if currentLabel != name { label.string = name.flatMap { labels[$0] }; currentLabel = name }
            let position = CGPoint(x: 664, y: min(139, max(5, scene.targetY - 8)))
            for text in [label, placeholder] {
                text.position = position; text.contentsScale = backingScale * size.width / 800
            }
            label.opacity = Float(scene.labelOpacity * 0.85)
            placeholder.opacity = Float((1 - scene.labelOpacity) * 0.4)
        }

        private func pencil(_ path: CGPath?, width: Double, opacity: Double, in parent: CALayer) -> PencilPair {
            let pair = PencilPair(parent: parent, path: path, width: width, opacity: opacity)
            pairs.append(pair); return pair
        }
        private func configure(_ shape: CAShapeLayer, in parent: CALayer) {
            shape.bounds = parent.bounds
            shape.position = CGPoint(x: parent.bounds.midX, y: parent.bounds.midY)
            shape.isGeometryFlipped = false; shape.lineCap = .round; shape.lineJoin = .round
            parent.addSublayer(shape)
        }

        @MainActor
        private final class PencilPair {
            let halo = CAShapeLayer(), ink = CAShapeLayer()
            init(parent: CALayer, path: CGPath?, width: Double, opacity: Double) {
                for layer in [halo, ink] {
                    layer.bounds = parent.bounds
                    layer.position = CGPoint(x: parent.bounds.midX, y: parent.bounds.midY)
                    layer.isGeometryFlipped = false; layer.fillColor = nil
                    layer.lineCap = .round; layer.lineJoin = .round
                    parent.addSublayer(layer)
                }
                halo.strokeColor = CGColor(gray: 0.98, alpha: 1)
                halo.lineWidth = width + 1.25; ink.lineWidth = width
                setPath(path); setOpacity(opacity)
            }
            func setPath(_ path: CGPath?) { halo.path = path; ink.path = path }
            func setOpacity(_ opacity: Double) { halo.opacity = Float(opacity * 0.8); ink.opacity = Float(opacity) }
            func setLineWidth(_ width: Double, haloWidth: Double) {
                ink.lineWidth = width; halo.lineWidth = width + haloWidth
            }
        }
    }
}
