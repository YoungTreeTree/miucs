import Foundation
import Combine

/// One small preference for every visualization. No audio work or per-frame observation.
@MainActor
final class VisualizationAppearanceStore: ObservableObject {
    static let preferencesKey = "MiucsVisualizationInk.v1"
    @Published private(set) var selection: VisualizationInk
    private let preferences: UserDefaults
    var appearance: VisualizationAppearance { selection.appearance }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let raw = preferences.string(forKey: Self.preferencesKey) {
            selection = VisualizationInk(rawValue: raw) ?? .graphite
        } else if let data = preferences.data(forKey: PencilPaletteStore.preferencesKey),
                  let legacy = try? JSONDecoder().decode(PencilPalette.self, from: data) {
            selection = VisualizationInk.nearest(to: legacy.bird)
        } else { selection = .graphite }
    }
    // Called only by a normal launch, so offline diagnostics remain read-only.
    func saveSelection() { preferences.set(selection.rawValue, forKey: Self.preferencesKey) }
    func select(_ ink: VisualizationInk) {
        guard selection != ink else { return }
        preferences.set(ink.rawValue, forKey: Self.preferencesKey)
        selection = ink
    }
}
