import AppKit

@main struct PluginReloadTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let api=PluginNative.shared
        precondition(api.available,"Bundle must include the plugin dylib and worker")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("miucs-plugin-reload-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let manifest="""
        {"id":"test","name":"Reload","version":"1.0.0","api":1,"entry":"main.lua","inputs":[],"layout":{"width":100,"height":100,"minimumWidth":10,"maximumWidth":200}}
        """
        try manifest.write(to:directory.appendingPathComponent("manifest.json"),atomically:true,encoding:.utf8)
        func source(_ text:String)throws {try text.write(to:directory.appendingPathComponent("main.lua"),atomically:true,encoding:.utf8)}
        func script(_ color:String)->String {"return {create=function() miucs.load{type='rect',id='test',width=100,height=100,fill='\(color)'} end,activate=function(v) assert(v.width==100 and v.height==100 and v.scale==2) end}"}
        try source(script("#ff0000"))
        let package=PluginPackage(["id":"test","directory":directory.path]);defer{package.close()}
        func wait(_ condition:()->Bool)throws {
            let until=Date().addingTimeInterval(4)
            while !condition() {
                if Date()>until {throw NSError(domain:"Plugin reload timeout",code:1)}
                RunLoop.current.run(until:Date().addingTimeInterval(0.01));package.pollReload()
            }
        }
        try wait { api.ready?(package.handle)==1 }
        package.activeID="test";package.post("activate",["id":"test","width":100,"height":100,"scale":2])
        try wait { (api.completed?(package.handle) ?? 0)>=2 }
        let original=package.handle
        try source("this is invalid Lua")
        package.requestReload();try wait { !package.reloadError.isEmpty }
        precondition(package.handle==original,"Failed reload must preserve live worker")
        try source(script("#0000ff"))
        package.requestReload();try wait { package.handle != original }
        precondition(package.reloadError.isEmpty)
        let surface="test".withCString {api.createSurface?(package.handle,nil,$0)}!
        defer { api.destroySurface?(surface) }
        var pixels=[UInt8](repeating:0,count:16*16*4)
        precondition(api.pixels?(surface,16,16,&pixels,pixels.count)==1 && pixels[0]==255 && pixels[2]==0,"Replacement scene must render blue")
        // A plain CALayer selects CPU fallback. Reloads reuse this same parent layer.
        let layer=CALayer();layer.bounds=CGRect(x:0,y:0,width:100,height:100)
        for _ in 0..<10 {
            let cpu="test".withCString {api.createSurface?(package.handle,Unmanaged.passUnretained(layer).toOpaque(),$0)}!
            precondition(api.backend?(cpu)==0 && api.draw?(cpu,100,100,1)==1)
            precondition(layer.sublayers?.count==1)
            let child=layer.sublayers!.first!
            precondition(child.contents != nil)
            api.destroySurface?(cpu)
            precondition(layer.sublayers?.isEmpty ?? true,"Disposal removes the old CPU layer")
            precondition(child.superlayer==nil && child.contents==nil,"Disposal releases the last CPU frame")
        }
        print("PASS CPU surface disposal: 10 reload cycles retain no layers or frame contents")
        // Catalog scans do not create workers; each selection starts only its own package.
        let host=PluginHost.shared, registry=PluginVisualizations.registry()
        let ids=Set(["pixel-keyboard","muffin-puppies","niulai-keyboard","heiji-kazuha"])
        precondition(ids.isSubset(of:Set(registry.descriptors.map(\.id))))
        precondition(host.packages.isEmpty,"Tray must not eagerly launch a plugin")
        precondition(registry.descriptors.prefix(4).map(\.id)==["pixel-keyboard","muffin-puppies","niulai-keyboard","heiji-kazuha"])
        precondition(registry.descriptor(id:"pixel-keyboard")?.name=="奶牛猫")
        let suite="MiucsCuratedPlugins-"+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        for saved in [nil,"removed-plugin","muffin-puppies","pixel-keyboard"] as [String?] {
            if let saved { preferences.set(saved,forKey:VisualizerPanel.selectionPreferencesKey) }
            else { preferences.removeObject(forKey:VisualizerPanel.selectionPreferencesKey) }
            let panel=VisualizerPanel(source:FeatureChannel(),registry:registry,preferences:preferences,persistsFrame:false,monitorsHover:false)
            precondition(panel.descriptor.id==(saved=="muffin-puppies" ? "muffin-puppies" : "pixel-keyboard"),"First launch and missing plugins select the cat; valid choices survive")
            panel.visualizationHost.dispose()
            precondition(host.packages.isEmpty)
        }
        print("PASS featured cat ordering, renamed catalog and saved-selection fallback")
        let keys=KeyboardChannel()
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        let tray=AppTrayIcon(item:item,source:keys)
        defer {tray.stop();NSStatusBar.system.removeStatusItem(item);host.stop()}
        precondition(item.button?.image != nil,"Application logo exists without any plugin")
        for id in ids.sorted() {
            let selected=registry.makeSession(id:id)!
            precondition(selected is PluginSession,"Every catalog entry must use the plugin runtime")
            selected.activate(viewport:.desktop)
            precondition(Set(host.packages.keys)==Set([id]),"Only selected plugin owns a worker")
            selected.dispose()
            precondition(host.packages.isEmpty,"Switching/disposal releases the old worker")
            precondition(item.button?.image != nil,"Plugin disposal preserves application tray")
        }
        print("PASS independent plugin selection and application tray lifetime")
        print("PASS Mac plugin reload: syntax failure preserves live scene; successful candidate preserves viewport and swaps rendered output")
    }
}
