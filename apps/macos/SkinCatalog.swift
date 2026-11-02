import AppKit

/// A skin is one plugin package. Retired demos are not application choices.
struct SkinItem: Identifiable {
    let id: String
    let name: String
    let directory: URL
    let previewURL: URL?

    static let retiredIDs: Set<String> = ["staff-note", "pencil-flight"]

    init(id: String, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        previewURL = ["gif", "png", "webp", "jpg", "jpeg"].compactMap { ext -> URL? in
            let url = directory.appendingPathComponent("preview.\(ext)").resolvingSymlinksInPath()
            guard url.path.hasPrefix(root),
                  let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  info.isRegularFile == true, let size = info.fileSize, size <= 20_000_000,
                  NSImage(contentsOf: url) != nil else { return nil }
            return url
        }.first
    }
}
