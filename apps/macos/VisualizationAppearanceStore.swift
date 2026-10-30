import Foundation
import Combine

/// Shared appearance preferences. No audio work or per-frame observation.
@MainActor
final class VisualizationAppearanceStore: ObservableObject {
    static let preferencesKey = "MiucsVisualizationInk.v1"
    static let transparencyKey = "MiucsVisualizationTransparency.v1"
    static let opacityPresets = Array(stride(from: 10, through: 100, by: 10))
    @Published private(set) var selection: VisualizationInk
    @Published private(set) var transparency: Int
    var opacity: Int { 100 - transparency }
    func setOpacity(_ percent: Int) { setTransparency(100 - min(100, max(10, percent))) }
    private let preferences: UserDefaults
    var appearance: VisualizationAppearance { selection.appearance }

    // Decode only the saved ink needed to migrate existing installations.
    private struct PreviousPalette: Decodable { let bird: VisualizationColor }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        transparency = min(90, max(0, preferences.object(forKey: Self.transparencyKey) as? Int ?? 0))
        if let raw = preferences.string(forKey: Self.preferencesKey) {
            selection = VisualizationInk(rawValue: raw) ?? .graphite
        } else if let data = preferences.data(forKey: "MiucsPencilPalette.v1"),
                  let legacy = try? JSONDecoder().decode(PreviousPalette.self, from: data) {
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
    func setTransparency(_ percent: Int) {
        let value = min(90, max(0, percent))
        guard transparency != value else { return }
        preferences.set(value, forKey: Self.transparencyKey)
        transparency = value
    }
}
