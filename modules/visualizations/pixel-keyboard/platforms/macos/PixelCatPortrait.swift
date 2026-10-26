import AppKit
import ImageIO

/// Decoded once. Installed apps use the bundled asset; command-line native previews
/// use the same checked-in source asset without needing an application bundle.
@MainActor
enum PixelCatPortrait {
    static let image: CGImage? = {
        let sourceAsset = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/cat-head.png")
        let url = Bundle.main.url(forResource: "PixelCatHead", withExtension: "png")
            ?? Bundle.main.url(forResource: "cat-head", withExtension: "png")
            ?? sourceAsset
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
}
