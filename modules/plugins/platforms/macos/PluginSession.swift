import AppKit
import QuartzCore

@MainActor
final class PluginPackage {
    let directory: String
    let id: String
    var handle: UnsafeMutableRawPointer?
    var activeID: String?
    private var viewport: [String:Any] = [:]
    var appearance: [String: Any] = ["ink": "#3d3d3d"]
    var reloadError = ""
    var isReloading: Bool { candidate != nil }
    private var candidate: UnsafeMutableRawPointer?
    private var reloadStarted = 0.0
    private var fingerprint = ""
    var views = NSHashTable<PluginCanvas>.weakObjects()
    private let api = PluginNative.shared
    init(_ metadata: [String: Any]) {
        directory = metadata["directory"] as! String; id = metadata["id"] as! String
        handle = api.worker.withCString { worker in directory.withCString { root in api.open?(worker,root) } }
    }
    func post(_ op: String, _ value: [String: Any] = [:]) {
        if op == "activate" || op == "resize" { viewport=value }
        guard let handle else { return }
        let bytes = PluginMessagePack.encode(["op": op, "value": value])
        _ = bytes.withUnsafeBytes { api.post?(handle,$0.bindMemory(to: UInt8.self).baseAddress!,bytes.count) }
    }
    func checkFiles() {
        let url = URL(fileURLWithPath: directory)
        var files=[URL]()
        if let enumerator=FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey],options:[.skipsHiddenFiles]) {
            for case let file as URL in enumerator { files.append(file);if files.count>=4096 { break } }
        }
        files.sort { $0.path < $1.path }
        let value = files.prefix(4096).map { file -> String in
            let r = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(file.path):\(r?.fileSize ?? 0):\(r?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        defer { fingerprint = value }
        if fingerprint.isEmpty || fingerprint == value { return }
        requestReload()
    }
    func requestReload() {
        guard candidate == nil else { return }
        candidate = api.worker.withCString { worker in directory.withCString { root in api.open?(worker,root) } }
        reloadStarted = ProcessInfo.processInfo.systemUptime; reloadError = ""
        guard let candidate else { reloadError = api.failure(nil); return }
        func send(_ op: String, _ value: [String: Any]) {
            let bytes = PluginMessagePack.encode(["op": op, "value": value])
            _ = bytes.withUnsafeBytes { api.post?(candidate,$0.bindMemory(to: UInt8.self).baseAddress!,bytes.count) }
        }
        send(activeID == nil ? "deactivate" : "activate", viewport)
        send("appearanceChanged", appearance)
        send("update", ["now":reloadStarted,"deltaTime":0])
    }
    func pollReload() {
        guard let candidate else { return }
        let error = api.failure(candidate)
        if !error.isEmpty || ProcessInfo.processInfo.systemUptime-reloadStarted>3 {
            reloadError = error.isEmpty ? "Plugin reload timed out" : error
            api.close?(candidate);self.candidate=nil;return
        }
        guard (api.completed?(candidate) ?? 0)>=4 else { return }
        let output: String? = id
        if let output {
            guard let surface=output.withCString({ api.createSurface?(candidate,nil,$0) }) else { return }
            var pixels=[UInt8](repeating:0,count:16*16*4)
            let valid=api.pixels?(surface,16,16,&pixels,pixels.count)==1
            api.destroySurface?(surface)
            if !valid { reloadError=api.failure(nil);api.close?(candidate);self.candidate=nil;return }
        }
        for view in views.allObjects { view.releaseSurface() }
        let previous=handle;handle=candidate;self.candidate=nil
        if let previous { api.close?(previous) }
    }
    func close() {
        if let candidate { api.close?(candidate) };candidate=nil
        for view in views.allObjects { view.releaseSurface() }
        if let handle { api.close?(handle) }; handle = nil
    }
}

@MainActor
final class PluginHost {
    static let shared = PluginHost()
    private(set) var metadata = [[String: Any]]()
    private(set) var packages = [String: PluginPackage]()
    private(set) var errors = [String]()
    private var audioSource: (any AudioFeatureSource)?
    private var keyboardSource: (any KeyboardFeatureSource)?
    private var audio: FeatureSubscription?
    private var keyboard: KeyboardSubscription?
    private var timer: Timer?
    private var last = 0.0
    private var suspended = false
    private var suspensionReasons = Set<String>()
    private var registeredIDs = Set<String>()
    private var observers = [NSObjectProtocol]()
    private var lastScan = 0.0
    func register(in registry: VisualizationRegistry) {
        guard PluginNative.shared.available else { errors=["插件运行库不可用；请安装完整应用或重新运行 build.sh。"];return }
        let result = PluginNative.shared.scan()
        metadata = result["plugins"] as? [[String: Any]] ?? []
        errors = (result["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
        let nextIDs=Set(metadata.compactMap { $0["id"] as? String })
        for id in registeredIDs.subtracting(nextIDs) { registry.remove(id: id) };registeredIDs=nextIDs
        for package in metadata {
            guard let id = package["id"] as? String, let name = package["name"] as? String, let l = package["layout"] as? [String: Double], let w = l["width"], let h = l["height"], let lo = l["minimumWidth"], let hi = l["maximumWidth"] else { continue }
            let descriptor = VisualizationDescriptor(id: id, name: name, layout: VisualizationLayout(width: w,height: h,minimumWidth: lo,maximumWidth: hi))
            registry.replace(descriptor) { PluginSession(descriptor: descriptor, package: self.package(package)) }
        }
    }
    func package(_ metadata: [String: Any]) -> PluginPackage {
        let id = metadata["id"] as! String
        if let existing = packages[id] { return existing }
        let result = PluginPackage(metadata); packages[id] = result; return result
    }
    func start(audio: any AudioFeatureSource, keyboard: any KeyboardFeatureSource) {
        guard PluginNative.shared.available else { return }
        audioSource = audio; keyboardSource = keyboard; self.audio = audio.subscribe(); self.keyboard = keyboard.subscribe()
        last = ProcessInfo.processInfo.systemUptime
        updateSchedule()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setSuspended(true, reason: name == NSWorkspace.willSleepNotification ? "sleep" : "session") } })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setSuspended(false, reason: name == NSWorkspace.didWakeNotification ? "sleep" : "session") } })
        }
    }
    private func setSuspended(_ value: Bool, reason: String) {
        if value { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        suspended = !suspensionReasons.isEmpty;updateSchedule(); last = ProcessInfo.processInfo.systemUptime
        audio = audioSource?.subscribe(); keyboard = keyboardSource?.subscribe()
        if suspended {
            for package in packages.values { package.post("update", ["now": last,"deltaTime": 0,"keyboard": ["sessionID":"suspended","sequence":0,"sampledAt":last,"state":"suspended","events":[]] as [String:Any]]) }
        }
    }
    func updateSchedule() {
        let needed = !suspended && packages.values.contains { $0.activeID != nil || $0.isReloading }
        guard needed else { timer?.invalidate();timer=nil;return }
        guard timer == nil else { return }
        last=ProcessInfo.processInfo.systemUptime
        audio=audioSource?.subscribe();keyboard=keyboardSource?.subscribe()
        timer=Timer(timeInterval: 1.0/60, repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer!,forMode:.common)
    }
    private func tick() {
        guard !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now-last >= 1.0/60 * 0.85 else { return }
        let dt = max(0,now-last); last = now
        var frame: [String: Any] = ["now":now,"deltaTime":dt]
        if let audio { frame["audio"] = PluginInput.audio(audio.read()) }
        if let keyboard { frame["keyboard"] = PluginInput.keyboard(keyboard.read()) }
        if ProcessInfo.processInfo.environment["MIUCS_PLUGIN_DEV"] == "1", now-lastScan>1 {
            lastScan=now;for package in packages.values { package.checkFiles() }
        }
        for package in packages.values {
            package.pollReload()
            if !package.reloadError.isEmpty, !errors.contains(package.reloadError) { errors.append(package.reloadError) }
        }
        for package in packages.values where package.activeID != nil {
            package.post("update",frame)
            let error = PluginNative.shared.failure(package.handle)
            if !error.isEmpty, !errors.contains(error) { errors.append(error); fputs("Plugin: \(error)\n",stderr) }
        }
        updateSchedule()
    }
    func releaseUnused(_ package: PluginPackage) {
        guard package.activeID == nil else { return }
        package.close();packages.removeValue(forKey:package.id)
    }
    func reloadActive() { errors=[];for package in packages.values { package.requestReload() };updateSchedule() }
    func stop() {
        timer?.invalidate(); timer=nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers=[]
        for package in packages.values { package.close() }; packages=[:]
    }
}

@MainActor
final class PluginCanvas: NSView {
    let package: PluginPackage
    let output: String
    private var surface: UnsafeMutableRawPointer?
    private var lastDraw = 0.0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(package: PluginPackage, output: String) {
        self.package=package;self.output=output
        super.init(frame:.zero);wantsLayer=true
        let metal=CAMetalLayer();metal.isOpaque=false;layer=metal
        package.views.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func releaseSurface() { if let surface { PluginNative.shared.destroySurface?(surface) }; surface=nil }
    func present() {
        guard let layer, package.handle != nil else { return }
        if surface == nil {
            surface=output.withCString { PluginNative.shared.createSurface?(package.handle,Unmanaged.passUnretained(layer).toOpaque(),$0) }
            if let surface, PluginNative.shared.backend?(surface)==0 { fputs("Plugin \(output): CPU fallback, 30 FPS limit\n",stderr) }
        }
        guard let surface else { return }
        let now=ProcessInfo.processInfo.systemUptime
        let gpu=PluginNative.shared.backend?(surface)==1
        guard now-lastDraw >= (gpu ? 1.0/60 : 1.0/30)*0.85 else { return };lastDraw=now
        let scale=window?.backingScaleFactor ?? 1
        let width=UInt32(max(1,min(8192,bounds.width*scale))), height=UInt32(max(1,min(8192,bounds.height*scale)))
        _=PluginNative.shared.draw?(surface,width,height,scale)
    }
}

@MainActor
final class PluginSession: MacVisualizationSession {
    let descriptor: VisualizationDescriptor
    let package: PluginPackage
    let canvas: PluginCanvas
    var view: NSView { canvas }
    var settingsTitle: String? { nil }
    init(descriptor: VisualizationDescriptor, package: PluginPackage) { self.descriptor=descriptor;self.package=package;canvas=PluginCanvas(package:package,output:descriptor.id) }
    func activate(viewport: VisualizationViewport) { package.activeID=descriptor.id;package.post("activate",viewportValue(viewport));PluginHost.shared.updateSchedule() }
    func resize(to viewport: VisualizationViewport) { package.post("resize",viewportValue(viewport)) }
    func update(input: FeatureInput, deltaTime: Double) { canvas.present() }
    func applyAppearance(_ value: VisualizationAppearance) {
        let ink=value.ink
        package.appearance=["ink":String(format:"#%02x%02x%02x",Int(ink.red*255),Int(ink.green*255),Int(ink.blue*255))]
        package.post("appearanceChanged",package.appearance)
    }
    func deactivate() { if package.activeID==descriptor.id { package.activeID=nil;package.post("deactivate");PluginHost.shared.updateSchedule() } }
    func dispose() { deactivate();canvas.releaseSurface();PluginHost.shared.releaseUnused(package) }
    func presentSettings() {}
    private func viewportValue(_ v: VisualizationViewport)->[String:Any] { ["id":descriptor.id,"width":v.width,"height":v.height,"scale":v.scale] }
}
