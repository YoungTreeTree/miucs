import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Compile with KeyboardInput.swift, KeyboardChannel.swift and TrayHeadAnimation.swift.
/// This previews the actual scene and original portrait, not the generated pose sheet.
@main struct HeadPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = root.appendingPathComponent("docs/concepts/pixel-cat-head")
        let asset = root.appendingPathComponent("apps/assets/cat-head.png")
        let source = CGImageSourceCreateWithURL(asset as CFURL, nil)!
        let headImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let gifURL = folder.appendingPathComponent("typing-head-preview-v1.gif")
        let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 150, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        var scenes = [TrayHeadAnimation(), TrayHeadAnimation(), TrayHeadAnimation()]
        let sessions = [UUID(), UUID(), UUID()], rates = [1,2,4]
        var sequences = [UInt64](repeating: 0, count: 3)
        func label(_ text: String, center: Double, y: Double, size: Double, bold: Bool = false) {
            let value = NSAttributedString(string: text, attributes: [
                .font:NSFont.systemFont(ofSize:size, weight:bold ? .semibold : .regular),
                .foregroundColor:NSColor(calibratedRed:0.26, green:0.23, blue:0.31, alpha:1)])
            value.draw(at:NSPoint(x:center-value.size().width/2, y:y))
        }
        // Warm up to steady typing. 5-second recording gives exactly 2/4/8 cycles.
        for frame in 0..<300 {
            let t = Double(frame)/30
            for i in 0..<3 {
                let press = frame == 0 || frame*rates[i]/30 != (frame-1)*rates[i]/30
                var events = [KeyboardInputEvent]()
                if press {
                    sequences[i] += 1
                    events = [KeyboardInputEvent(sequence:sequences[i],receivedAt:t,kind:.pressed,keyCode:0,modifiers:[],heldDuration:nil)]
                }
                let input = KeyboardInput(sessionID:sessions[i],sequence:sequences[i],state:.running,sampledAt:t,
                    modifiers:[],heldKeys:[],pressesPerSecond:Double(rates[i]),idleDuration:0,events:events,droppedEventCount:0)
                scenes[i].advance(seconds:1.0/30,input:input)
            }
            if frame < 150 { continue }
            let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:960,pixelsHigh:440,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep:rep)!
            NSGraphicsContext.current = context
            let cg = context.cgContext
            NSColor(calibratedRed:0.965,green:0.95,blue:0.97,alpha:1).setFill()
            CGRect(x:0,y:0,width:960,height:440).fill()
            label("打字越快，猫头摇得越快",center:480,y:394,size:24,bold:true)
            for i in 0..<3 {
                let x = Double(i)*312+24, center = x+144
                NSColor(calibratedRed:0.985,green:0.975,blue:0.95,alpha:1).setFill()
                CGRect(x:x,y:42,width:288,height:334).fill()
                label(["慢速输入","正常输入","快速输入"][i],center:center,y:341,size:19,bold:true)
                cg.saveGState(); cg.interpolationQuality = .none
                cg.translateBy(x:center,y:158)
                // The app uses downward screen coordinates; negate for this bitmap context.
                cg.rotate(by:-scenes[i].angle)
                cg.draw(headImage,in:CGRect(x:-90,y:-180*0.12,width:180,height:180))
                cg.restoreGState()
                label("每秒 \(rates[i]) 次按键",center:center,y:105,size:17)
                label(String(format:"摇头 %.1f 次 / 秒",Double(rates[i])*0.4),center:center,y:79,size:14)
                let pulse = (t*Double(rates[i])).truncatingRemainder(dividingBy:1) < 0.18
                (pulse ? NSColor(calibratedRed:0.90,green:0.53,blue:0.53,alpha:1) : NSColor(calibratedRed:0.82,green:0.78,blue:0.86,alpha:1)).setFill()
                CGRect(x:center-24,y:55,width:48,height:8).fill()
            }
            label("相同摆幅 · 固定下巴支点 · 停止输入后平缓回正",center:480,y:13,size:13)
            NSGraphicsContext.restoreGraphicsState()
            // 30fps represented with alternating 30/40ms GIF delays, exactly five seconds.
            let delay = frame % 3 == 2 ? 0.04 : 0.03
            CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay]] as CFDictionary)
            if frame == 180 { try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("typing-head-preview-v1.png")) }
        }
        precondition(CGImageDestinationFinalize(gif))
        print("Saved 150-frame / 5-second GIF: \(gifURL.path)")
    }
}
