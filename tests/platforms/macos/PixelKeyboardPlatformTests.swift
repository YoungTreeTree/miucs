import AppKit
import ImageIO
import UniformTypeIdentifiers

@main @MainActor enum PixelKeyboardPlatformTests {
    static func bitmap(_ view: PixelKeyboardView, width: Int = 800, background: NSColor? = nil) -> NSBitmapImageRep {
        let height = Int(Double(width)*460/800)
        view.setFrameSize(NSSize(width: width, height: height)); view.layoutSubtreeIfNeeded()
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
            feature.beat = BeatFrame(time:t,bpm:120,phase:0,confidence:0.9,strength:0.8,beatTime:index%30 == 0 ? t : nil)
            if press {keys.publish(KeyboardRawEvent(kind:.pressed,keyCode:0,modifiers:[]),sessionID:keyID)}
            if release {keys.publish(KeyboardRawEvent(kind:.released,keyCode:0,modifiers:[]),sessionID:keyID)}
            audio.publish(audio:feature,melody:StaffNotePreview.melody(t,midi:[67.0,69,71,72,74,72,69,67][(index/30)%8]),sessionID:audioID)
            session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)
        }
        for i in 0..<180 { tick(i,press:i==170) }
        check("Beats and keyboard drive tail and paws together", session.keyboard.pressed.contains(.a) && session.tail.beatCount == 6)
        check("Typing drives the head alongside the music tail", session.head.amplitude > 0.5 && abs(session.head.angle) > 0.01)
        let headPhase = session.head.phase
        audio.reset(sessionID:UUID(),state:.permissionRequired)
        session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)
        check("Audio loss cannot reset held keys", session.keyboard.pressed.contains(.a))
        check("Audio reconnect cannot reset typing-driven head phase", session.head.phase > headPhase)
        let portrait = session.drawing.layer?.sublayers?.first?.sublayers?.first { $0.name == "pixel-cat-portrait" }
        check("Native portrait rotates about the fixed chin pivot", portrait?.anchorPoint == CGPoint(x:0.5,y:0.88) &&
            portrait?.position == CGPoint(x:76,y:54+64*0.88) && abs(atan2(portrait!.affineTransform().b,portrait!.affineTransform().a)-session.head.angle)<0.00001)
        keys.publish(KeyboardRawEvent(kind:.released,keyCode:0,modifiers:[]),sessionID:keyID)
        for _ in 0..<30 {session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)}
        check("Key release works without audio", session.keyboard.pressed.isEmpty && session.keyboard.left.down == 0)
        check("Audio loss lets the tail settle while keys remain independent", session.tail.spriteIndex == 0)
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
            colored = colored && session.hintColor == ink.color.nsColor
            for (name,bg) in [("light",NSColor.white),("dark",NSColor(calibratedWhite:0.12,alpha:1))] {
                let rep=bitmap(session.drawing,background:bg)
                try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(ink.rawValue)-\(name).png"))
            }
        }
        let screenBitmap = bitmap(session.drawing)
        var centerInk = 0, tailInk = 0
        for y in 24..<146 { for x in 116..<638 {
            let c = screenBitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if c.redComponent < 0.8 || c.greenComponent < 0.8 { centerInk += 1 }
        } }
        for y in 40..<128 { for x in 652..<748 {
            let c = screenBitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if c.redComponent < 0.01 && c.greenComponent < 0.01 && c.blueComponent < 0.01 { tailInk += 1 }
        } }
        check("Screen center stays completely blank without staff or music effects", centerInk == 0)
        check("Pure black pixel tail is visible in the right column", tailInk > 250)
        let catPixel = screenBitmap.colorAt(x:76,y:90)!.usingColorSpace(.deviceRGB)!
        check("Left portrait remains visible at its original scale", catPixel.redComponent < 0.6)
        check("Global ink applies only to status, preserving the black tail", colored)
        let sprites = (0..<PixelTailSprite.frameCount).map { PixelTailSprite.pixels(index:$0) }
        check("All tail poses fit beside the portrait without clipping or moving the root", sprites.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.0 >= 2 && $0.0 <= 92 && $0.1 >= 2 && $0.1 <= 84 } && $0.contains { $0.0 == 12 && $0.1 == 48 }
        })
        let rest = PixelTailSprite.pixels(index:0)
        check("Resting tail extends horizontally at the same scale as the portrait", rest.map { $0.0 }.max()! - rest.map { $0.0 }.min()! > 60 && rest.map { $0.1 }.max()! - rest.map { $0.1 }.min()! < 36)
        let middleA = PixelTailSprite.centerline(t:0.5,phase:1.2,amplitude:1).1 - PixelTailSprite.centerline(t:0.5,phase:1.2,amplitude:0).1
        let tipA = PixelTailSprite.centerline(t:1,phase:1.2,amplitude:1).1 - PixelTailSprite.centerline(t:1,phase:1.2,amplitude:0).1
        let middleB = PixelTailSprite.centerline(t:0.5,phase:2.4,amplitude:1).1 - PixelTailSprite.centerline(t:0.5,phase:2.4,amplitude:0).1
        let tipB = PixelTailSprite.centerline(t:1,phase:2.4,amplitude:1).1 - PixelTailSprite.centerline(t:1,phase:2.4,amplitude:0).1
        check("A delayed bend travels from the middle toward the tip", abs(middleA) < 0.01 && abs(tipA) > 8 && abs(middleB) > 3 && abs(tipB) < 0.01)
        check("Rounded tail retains a broad shaft and tip in every pose", sprites.allSatisfy { pixels in
            [24,48,70].allSatisfy { column in pixels.filter { $0.0 == column }.count >= 5 }
        })
        let areas = sprites.map { $0.count }
        check("Tail volume stays consistent throughout the swish", Double(areas.max()!) / Double(areas.min()!) < 1.2)
        let rootCells = Set(rest.filter { $0.0 <= 14 }.map { $0.1 * 96 + $0.0 })
        check("The full root silhouette stays anchored", sprites.allSatisfy {
            Set($0.filter { $0.0 <= 14 }.map { $0.1 * 96 + $0.0 }) == rootCells
        })
        let loop = sprites[193...256].map { Set($0.map { $0.1 * 96 + $0.0 }) }
        check("Adjacent poses and the loop seam have no large jumps", (0..<64).allSatisfy {
            loop[$0].symmetricDifference(loop[($0+1)%64]).count < 60
        })
        var tail = PixelTailScene(), tailID = UUID()
        func tailInput(_ seq:UInt64, now:Double, beat:Bool=false, bpm:Double=120, confidence:Double=0.9, lag:Double=0, silent:Bool=false, strength:Double=1, onset:Bool=false) -> FeatureInput {
            var sound=StaffNotePreview.audio(now);sound.isSilent=silent
            let frame=AudioFeatureFrame(sessionID:tailID,sequence:seq,receivedAt:now,audio:sound,melody:nil)
            return FeatureInput(sessionID:tailID,state:.running,frame:frame,frameAge:0,onsets:onset ? [AudioOnsetEvent(sequence:seq,time:now,receivedAt:now-lag,strength:strength)] : [],spectralFluxPeak:0,
                beats:beat ? [AudioBeatEvent(sequence:seq,time:now,receivedAt:now-lag,strength:strength,bpm:bpm,confidence:confidence)] : [])
        }
        var responsive = PixelTailScene()
        responsive.advance(tailInput(1,now:0,beat:true,strength:0.1),seconds:0)
        responsive.advance(tailInput(2,now:0.05),seconds:0.05)
        check("A quiet reliable beat reaches visible half-amplitude within 50ms", responsive.amplitude > 0.5 && responsive.spriteIndex > 64)
        tail.advance(tailInput(1,now:0,beat:true),seconds:0)
        tail.advance(tailInput(2,now:0.4),seconds:0.4)
        let phaseBeforeBeat=tail.phase
        tail.advance(tailInput(3,now:0.5,beat:true),seconds:0.1)
        tail.advance(tailInput(4,now:0.9),seconds:0.4)
        check("Fresh beats preserve continuous motion instead of flipping the tail", phaseBeforeBeat > 0 && tail.phase > phaseBeforeBeat && tail.beatCount == 2 && tail.amplitude > 0.9)
        tail.advance(tailInput(4,now:0.9,beat:true),seconds:0)
        tail.advance(tailInput(5,now:1,beat:true,confidence:0.1),seconds:0.1)
        tail.advance(tailInput(6,now:1.1,beat:true,lag:1),seconds:0.1)
        check("Repeated, unreliable and stale beats never trigger swings", tail.beatCount == 2)
        tail.advance(tailInput(7,now:5),seconds:4)
        check("Long gaps settle directly without queued swings", tail.amplitude == 0)
        tail.advance(tailInput(8,now:5.1,beat:true),seconds:0)
        tail.advance(tailInput(9,now:5.2),seconds:0.1)
        tail.advance(tailInput(10,now:5.5,silent:true),seconds:0.3)
        check("Silence returns the tail to rest", tail.amplitude == 0)
        tailID=UUID();tail.advance(tailInput(1,now:6,beat:true,lag:1),seconds:1)
        check("Reconnect ignores old beats", tail.beatCount == 0 && tail.amplitude == 0)
        var unlocked = PixelTailScene()
        unlocked.advance(tailInput(1,now:0,strength:0.5,onset:true),seconds:1/60)
        unlocked.advance(tailInput(2,now:0.1),seconds:0.1)
        check("Music attacks animate the tail before BPM locks", unlocked.onsetCount == 1 && unlocked.beatCount == 0 && unlocked.amplitude > 0.5)
        unlocked.advance(tailInput(2,now:0.1,strength:0.5,onset:true),seconds:0)
        unlocked.advance(tailInput(3,now:0.3,lag:1,strength:0.5,onset:true),seconds:0.2)
        unlocked.advance(tailInput(4,now:0.4,strength:0.1,onset:true),seconds:0.1)
        check("Repeated stale and weak attacks cannot retrigger the tail", unlocked.onsetCount == 1)
        unlocked.advance(tailInput(5,now:0.5,beat:true,onset:true),seconds:0.1)
        unlocked.advance(tailInput(6,now:0.7,onset:true),seconds:0.2)
        check("Reliable beats take priority without double-triggering", unlocked.beatCount == 1 && unlocked.onsetCount == 1)
        unlocked.advance(tailInput(7,now:2,strength:0.5,onset:true),seconds:1.3)
        check("Fresh attacks resume motion after tempo lock is lost", unlocked.onsetCount == 2)
        unlocked.advance(tailInput(8,now:2.01,strength:0.5,onset:true),seconds:0.01)
        check("Dense attacks are coalesced rather than queued", unlocked.onsetCount == 2)
        unlocked.advance(tailInput(9,now:2.31,silent:true,onset:true),seconds:0.3)
        check("Silence stops fallback motion even with an attack event", unlocked.amplitude == 0 && unlocked.onsetCount == 2)
        unlocked.advance(tailInput(10,now:5),seconds:2.69)
        check("Unpitched sustained audio without attacks does not invent a rhythm", unlocked.amplitude == 0)
        tailID=UUID();unlocked.advance(tailInput(1,now:6,lag:1,onset:true),seconds:1)
        check("Reconnection never replays fallback attacks", unlocked.onsetCount == 0 && unlocked.amplitude == 0)
        var slow=PixelTailScene(), fast=PixelTailScene()
        slow.advance(tailInput(1,now:0,beat:true,bpm:60),seconds:0)
        fast.advance(tailInput(1,now:0,beat:true,bpm:180),seconds:0)
        slow.advance(tailInput(2,now:0.2),seconds:0.2)
        fast.advance(tailInput(2,now:0.2),seconds:0.2)
        check("Higher BPM drives a faster swing", fast.phase > slow.phase + 0.4)
        session.deactivate()
        check("Hide clears held keys and restores the resting tail", session.keyboard.pressed.isEmpty && session.tail.amplitude == 0)
        check("Hide returns the cat head to its original orientation", session.head.angle == 0 && portrait?.affineTransform() == .identity)
        session.activate(viewport:.desktop)
        session.receive(keyboard:keyboard.read());session.update(input:sounds.read(),deltaTime:1/60)
        check("Resume does not replay historical keyboard events", session.keyboard.litKeys.isEmpty)
        // Synthetic demonstration: independently moving paws and beat-driven tail.
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
            let beats = frame%10 == 0 ? [AudioBeatEvent(sequence:UInt64(frame+1),time:t,receivedAt:t,strength:0.9,bpm:120,confidence:0.9)] : []
            demo.update(input:FeatureInput(sessionID:musicID,state:.running,frame:audioFrame,frameAge:0,onsets:[],spectralFluxPeak:0,beats:beats),deltaTime:0.05)
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
