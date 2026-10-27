import AppKit
import ImageIO
import UniformTypeIdentifiers

// Assemble AI-drawn poses only: preserve silhouettes and use one scale for all frames.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let source = CGImageSourceCreateWithURL(directory.appendingPathComponent("motion-slim-sprites-v2.png") as CFURL, nil)!
let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let color = CGColorSpaceCreateDeviceRGB()
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func background(_ ctx: CGContext) {
    ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.interpolationQuality = .none
}
func png(_ image: CGImage, _ name: String) {
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
let inspection = context(sheet.width, sheet.height)
background(inspection)
inspection.draw(sheet, in: CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
png(inspection.makeImage()!, "motion-slim-sheet-preview-v2.png")

var frames: [CGImage] = []
for index in 0..<16 {
    let x0 = (index % 4) * sheet.width / 4
    let y0 = (index / 4) * sheet.height / 4
    let x1 = (index % 4 + 1) * sheet.width / 4
    let y1 = (index / 4 + 1) * sheet.height / 4
    let cell = sheet.cropping(to: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0))!
    let scan = context(cell.width, cell.height)
    scan.draw(cell, in: CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
    let bytes = scan.data!.assumingMemoryBound(to: UInt8.self)
    var minX = cell.width, maxX = 0, minY = cell.height, maxY = 0
    for y in 0..<cell.height { for x in 0..<cell.width {
        if bytes[(y * cell.width + x) * 4 + 3] > 127 {
            minX = min(minX,x); maxX = max(maxX,x)
            minY = min(minY,y); maxY = max(maxY,y)
        }
    }}
    var rootSum = 0.0, rootCount = 0.0
    for y in 0..<cell.height { for x in minX..<min(minX+12,cell.width) {
        if bytes[(y * cell.width + x) * 4 + 3] > 127 { rootSum += Double(y); rootCount += 1 }
    }}
    let rootY = rootSum / rootCount
    print("Frame \(index+1): bounds \(minX),\(minY)–\(maxX),\(maxY), rootY \(rootY)")
    let canvas = context(640, 400)
    background(canvas)
    // Bitmap row zero is the top; Core Graphics drawing coordinates start at the bottom.
    canvas.draw(scan.makeImage()!, in: CGRect(x: 90-Double(minX)*2,
        y: 200-(Double(cell.height)-rootY)*2, width: Double(cell.width)*2, height: Double(cell.height)*2))
    frames.append(canvas.makeImage()!)
}
let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent("tail-motion-v2.gif") as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for frame in frames {
    CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(gif))
for index in [0,4,8,12] { png(frames[index], "tail-frame-\(index+1)-v2.png") }
let verification = CGImageSourceCreateWithURL(directory.appendingPathComponent("tail-motion-v2.gif") as CFURL, nil)!
print("GIF frames: \(CGImageSourceGetCount(verification)); 640×400; 1.28s loop")
