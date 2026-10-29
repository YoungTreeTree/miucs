import AppKit
import Darwin

@MainActor
final class PluginNative {
    static let shared = PluginNative()
    private let library: UnsafeMutableRawPointer?
    let open: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?)?
    let close: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    let post: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>, Int) -> Int32)?
    let ready: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?
    let completed: (@convention(c) (UnsafeMutableRawPointer?) -> UInt64)?
    let error: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Int)?
    let createSurface: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?)?
    let draw: (@convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Double) -> Int32)?
    let pixels: (@convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutablePointer<UInt8>, Int) -> Int32)?
    let backend: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?
    let destroySurface: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    let catalog: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>?, Int) -> Int)?
    private var apiVersion: UInt32 = 0
    var available: Bool { apiVersion == 1 && open != nil && close != nil && post != nil && ready != nil && completed != nil && error != nil && createSurface != nil && draw != nil && pixels != nil && backend != nil && destroySurface != nil && catalog != nil }
    let worker: String
    let builtin: String
    let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Miucs/Plugins").path
    private init() {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = Bundle.main.executableURL?.deletingLastPathComponent() ?? resources
        worker = executable.appendingPathComponent("miucs-plugin-worker").path
        builtin = resources.appendingPathComponent("Plugins").path
        let handle = dlopen(executable.appendingPathComponent("libmiucs_plugins.dylib").path, RTLD_NOW | RTLD_LOCAL)
        library = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let value = dlsym(handle, name) else { return nil }
            return unsafeBitCast(value, to: type)
        }
        apiVersion = symbol("miucs_plugin_api_version", (@convention(c) () -> UInt32).self)?() ?? 0
        open = symbol("miucs_plugin_open", (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?).self)
        close = symbol("miucs_plugin_close", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
        post = symbol("miucs_plugin_post", (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>, Int) -> Int32).self)
        ready = symbol("miucs_plugin_ready", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self)
        completed = symbol("miucs_plugin_completed", (@convention(c) (UnsafeMutableRawPointer?) -> UInt64).self)
        error = symbol("miucs_plugin_error", (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Int).self)
        createSurface = symbol("miucs_surface_create", (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?).self)
        draw = symbol("miucs_surface_draw", (@convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Double) -> Int32).self)
        pixels = symbol("miucs_surface_pixels", (@convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutablePointer<UInt8>, Int) -> Int32).self)
        backend = symbol("miucs_surface_backend", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self)
        destroySurface = symbol("miucs_surface_destroy", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
        catalog = symbol("miucs_plugin_catalog", (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>?, Int) -> Int).self)
    }
    func failure(_ handle: UnsafeMutableRawPointer?) -> String {
        var text = [CChar](repeating: 0, count: 2048)
        _ = error?(handle, &text, text.count)
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) }, as: UTF8.self)
    }
    func scan() -> [String: Any] {
        guard let catalog else { return [:] }
        let n = builtin.withCString { b in user.withCString { u in catalog(b,u,nil,0) } }
        guard n > 0, n < 2_097_152 else { return [:] }
        var text = [CChar](repeating: 0, count: n)
        _ = builtin.withCString { b in user.withCString { u in catalog(b,u,&text,n) } }
        return (try? JSONSerialization.jsonObject(with: Data(text.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) }))) as? [String: Any] ?? [:]
    }
}
