import Foundation

public struct PetSkin: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL
    public let inputs: Set<String>
    public let preview: URL?
}

/// Reads manifests and still previews without loading Lua, Skia or a worker process.
public enum PetCatalog {
    public static var bundledDirectory: URL {
        #if SWIFT_PACKAGE
        // Hosts copy the SwiftPM resource bundle into Contents/Resources when making an .app.
        if let resources = Bundle.main.resourceURL {
            let installed = resources.appendingPathComponent("Miucs_MiucsCore.bundle/plugins")
            if FileManager.default.fileExists(atPath: installed.path) { return installed }
        }
        return Bundle.module.bundleURL.appendingPathComponent("plugins")
        #else
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("Plugins")
        #endif
    }

    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Miucs/Plugins")
    }

    public static func scan(builtin: URL = bundledDirectory, user: URL? = userDirectory) -> [PetSkin] {
        var skins = [String: PetSkin]()
        for root in [builtin, user].compactMap({ $0 }) {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.path < $1.path }) {
                if let skin = read(folder) { skins[skin.id] = skin }
            }
        }
        return skins.values.sorted {
            if ($0.id == "pixel-keyboard") != ($1.id == "pixel-keyboard") { return $0.id == "pixel-keyboard" }
            return $0.id < $1.id
        }
    }

    private static func read(_ folder: URL) -> PetSkin? {
        let fm = FileManager.default
        guard let manifest = safeFile("manifest.json", in: folder) else { return nil }
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = json["api"] as? Int, api == 1,
              let id = json["id"] as? String, HardwarePetPack.nativeIDs.contains(id),
              let name = json["name"] as? String, !name.isEmpty, name.count <= 128,
              let entry = json["entry"] as? String,
              let inputs = json["inputs"] as? [String], Set(inputs).isSubset(of: ["audio", "keyboard"]),
              safeFile(entry, in: folder) != nil else { return nil }
        let preview = ["preview.png", "preview.jpg", "preview.jpeg"].compactMap { safeFile($0, in: folder) }.first
        guard fm.fileExists(atPath: manifest.path) else { return nil }
        return PetSkin(id: id, name: name, directory: folder, inputs: Set(inputs), preview: preview)
    }

    private static func safeFile(_ name: String, in folder: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
        let url = folder.appendingPathComponent(name)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }
}
