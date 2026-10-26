import AppKit
import ImageIO
import UniformTypeIdentifiers

@main @MainActor enum PixelKeyboardPlatformTests {
    static func bitmap(_ view: PixelKeyboardView, width: Int = 800, background: NSColor? = nil) -> NSBitmapImageRep {
        let height = Int(Double(width)*460/800)
        view.setFrameSize(NSSize(width: width, height: height)); view.layoutSubtreeIfNeeded(); view.staff.updateLayer()
        CATransaction.flush()
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,
            hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context = NSGraphicsContext(bitmapImageRep:rep)!.cgContext
        context.translateBy(x:0,y:Double(height));context.scaleBy(x:1,y:-1)
        if let background {context.setFillColor(background.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))}
        view.layer!.render(in:context)
        return rep
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = [[String:Any]]()
        func check(_ name:String,_ ok:Bool){checks.append(["name":name,"passed":ok]);print("\(ok ? "PASS" : "FAIL") \(name)")}
        let session = MacPixelKeyboardSession(), registry = BuiltInVisualizations.registry()
        check("Third visualization is selectable with its own proportional layout", registry.descriptors.map(\.id) == ["pencil-flight","staff-note","pixel-keyboard"] && session.descriptor.layout.height == 460)
        check("Transparent photo-derived cat portrait loads independently of an app bundle", PixelCatPortrait.image != nil &&
            PixelCatPortrait.image?.alphaInfo != CGImageAlphaInfo.none && PixelCatPortrait.image?.alphaInfo != CGImageAlphaInfo.noneSkipLast)
        session.activate(viewport:VisualizationViewport(width:800,height:460,scale:1))
        let audio = FeatureChannel(), keys = KeyboardChannel(), audioID = UUID(), keyID = UUID()
        audio.reset(sessionID:audioID,state:.running);keys.reset(sessionID:keyID,state:.running)
        let sounds=audio.subscribe(), keyboard=keys.subscribe()
        // Stable synthetic PCM-derived feature frames, no desktop input or private capture.
        func tick(_ index:Int, press:Bool=false, release:Bool=false) {
            let t=Double(index)/60
            var feature=StaffNotePreview.audio(t);feature.envelope = 0.03 + 0.15 * (0.5+0.5*sin(t*3))
            if press {keys.publish(KeyboardRawEvent(kind:.pressed,keyCode:0,modifiers:[]),sessionID:keyID)}
            if release {keys.publish(KeyboardRawEvent(kind:.released,keyCode:0,modifiers:[]),sessionID:keyID)}
            audio.publish(audio:feature,melody:StaffNotePreview.melody(t,midi:[67.0,69,71,72,74,72,69,67][(index/30)%8]),sessionID:audioID)
            session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)
        }
        for i in 0..<180 { tick(i,press:i==170) }
        check("Music and keyboard are consumed together", session.keyboard.pressed.contains(.a) && session.music.scene.trace.count > 10)
        let pitch=session.music.scene.pitch
        audio.reset(sessionID:UUID(),state:.permissionRequired)
        session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)
        check("Audio loss cannot reset held keys", session.keyboard.pressed.contains(.a))
        keys.publish(KeyboardRawEvent(kind:.released,keyCode:0,modifiers:[]),sessionID:keyID)
        for _ in 0..<30 {session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)}
        check("Key release works without audio", session.keyboard.pressed.isEmpty && session.keyboard.left.down == 0)
        // Use a composed music snapshot for screenshot comparisons and the delivered preview.
        session.drawing.staff.updatePreview(StaffNotePreview.sampleScene(midi:71))
        let output=URL(fileURLWithPath:"build/pixel-keyboard-preview")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var validSizes=true, transparent=true, colored=true
        for width in [600,800,1600] {
            let rep=bitmap(session.drawing,width:width)
            validSizes = validSizes && rep.pixelsHigh == width * 460 / 800
            transparent = transparent && rep.colorAt(x:0,y:rep.pixelsHigh-1)!.alphaComponent == 0
            try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("transparent-\(width).png"))
        }
        check("600/800/1600 widths retain transparent margins and exact module proportions", validSizes && transparent)
        for ink in VisualizationInk.allCases {
            session.applyAppearance(ink.appearance)
            colored = colored && session.drawing.staff.inkStyle == ink.appearance
            for (name,bg) in [("light",NSColor.white),("dark",NSColor(calibratedWhite:0.12,alpha:1))] {
                let rep=bitmap(session.drawing,background:bg)
                try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(ink.rawValue)-\(name).png"))
            }
        }
        let screenBitmap = bitmap(session.drawing)
        var screenInk = 0
        for y in 34..<130 { for x in 132..<740 {
            let c = screenBitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if c.redComponent < 0.8 && c.greenComponent < 0.8 { screenInk += 1 }
        } }
        check("Embedded music is actually visible inside the screen pixels", screenInk > 100)
        let catPixel = screenBitmap.colorAt(x:76,y:90)!.usingColorSpace(.deviceRGB)!
        check("Cat portrait occupies the reserved left margin without covering staff", catPixel.redComponent < 0.6 &&
            session.drawing.staff.frame == NSRect(x:116,y:22,width:640,height:128))
        check("Five global inks reach the embedded real staff renderer", colored && pitch != nil)
        session.deactivate()
        check("Hide clears held keys and the embedded music history", session.keyboard.pressed.isEmpty && session.music.scene.trace.isEmpty)
        session.activate(viewport:.desktop)
        session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)
        check("Resume does not replay historical keyboard events", session.keyboard.litKeys.isEmpty)
        // Synthetic demonstration: independently moving paws and the same staff pipeline.
        let demo=MacPixelKeyboardSession();demo.activate(viewport:.desktop);demo.applyAppearance(VisualizationInk.violet.appearance)
        let musicID=UUID(), demoKeyID=UUID();var seq:UInt64=0
        let gifURL=URL(fileURLWithPath:"docs/assets/miucs-pixel-keyboard.gif")
        let gif=CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,80,nil)!
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let codes:[UInt16]=[0,38,2,40,14,31,3,37,49,12,35,1,46,15,32,45]
        var held:UInt16?
        for frame in 0..<80 {
            let t=Double(frame)/20;var events=[KeyboardInputEvent]()
            if frame%5==0 {
                if let held {seq+=1;events.append(KeyboardInputEvent(sequence:seq,receivedAt:t,kind:.released,keyCode:held,modifiers:[],heldDuration:0.25))}
                held=codes[(frame/5)%codes.count];seq+=1
                events.append(KeyboardInputEvent(sequence:seq,receivedAt:t,kind:.pressed,keyCode:held!,modifiers:[],heldDuration:nil))
            }
            demo.receive(keyboard:KeyboardInput(sessionID:demoKeyID,sequence:seq,state:.running,sampledAt:t,modifiers:[],
                heldKeys:held.map{[KeyboardHeldKey(keyCode:$0,duration:0)]} ?? [],pressesPerSecond:4,idleDuration:0,events:events,droppedEventCount:0))
            let note=[67.0,69,71,72,74,72,69,67][(frame/10)%8]
            var sound=StaffNotePreview.audio(t);sound.envelope=0.03+0.15*(0.5+0.5*sin(t*3))
            let audioFrame=AudioFeatureFrame(sessionID:musicID,sequence:UInt64(frame+1),receivedAt:t,audio:sound,melody:StaffNotePreview.melody(t,midi:note))
            demo.update(input:FeatureInput(sessionID:musicID,state:.running,frame:audioFrame,frameAge:0,onsets:[],spectralFluxPeak:0),deltaTime:0.05)
            let rep=bitmap(demo.drawing,background:.white)
            CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.05]] as CFDictionary)
            if frame==65 {try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"docs/assets/miucs-pixel-keyboard.png"))}
        }
        check("Native synthetic audio plus keyboard demo exports successfully", CGImageDestinationFinalize(gif))
        let failed=checks.filter{!($0["passed"] as! Bool)}.count
        try JSONSerialization.data(withJSONObject:["passed":checks.count-failed,"failed":failed,"checks":checks],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:"docs/validation/pixel-keyboard-tests.json"))
        if failed>0 {exit(1)}
    }
}
