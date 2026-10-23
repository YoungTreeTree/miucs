import AppKit

extension VisualizationColor {
    init?(nsColor: NSColor) {
        guard let color = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var cgColor: CGColor { nsColor.cgColor }
}
