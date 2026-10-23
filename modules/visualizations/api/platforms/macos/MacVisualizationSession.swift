import AppKit

@MainActor
protocol MacVisualizationSession: VisualizationSession {
    var view: NSView { get }
    var settingsTitle: String? { get }
    var hintColor: NSColor { get }
    func presentSettings()
}

extension MacVisualizationSession {
    var hintColor: NSColor { NSColor(calibratedWhite: 0.24, alpha: 1) }
}
