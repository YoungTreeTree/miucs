import AppKit
import Combine


@MainActor
final class PencilPaletteStore: ObservableObject {
    static let preferencesKey = "MiucsPencilPalette.v1"
    @Published private(set) var palette: PencilPalette
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.preferencesKey),
           let saved = try? JSONDecoder().decode(PencilPalette.self, from: data) {
            palette = saved
        } else { palette = .graphite }
    }

    var preset: PencilPalettePreset? { PencilPalettePreset.all.first { $0.palette == palette } }
    var name: String { preset?.name ?? "我的配色" }

    func set(_ color: PencilColor, for part: PencilPart) {
        var updated = palette
        updated[part] = color
        apply(updated)
    }

    func apply(_ updated: PencilPalette) {
        guard updated != palette, let data = try? JSONEncoder().encode(updated) else { return }
        preferences.set(data, forKey: Self.preferencesKey)
        palette = updated
    }

    func useForAll(_ color: PencilColor) {
        apply(PencilPalette(bird: color, gates: color, notes: color, scenery: color, trail: color))
    }

    func reset() {
        preferences.removeObject(forKey: Self.preferencesKey)
        if palette != .graphite { palette = .graphite }
    }
}
