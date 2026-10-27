import Foundation

/// Continuous traveling bend, gently paced by reliable beats. No queued impulses.
struct PixelTailScene {
    private(set) var amplitude = 0.0
    private(set) var phase = 0.0
    private(set) var beatCount = 0
    var spriteIndex: Int {
        let level = min(4, max(0, Int((amplitude * 4).rounded())))
        return level == 0 ? 0 : 1 + (level - 1) * 64 + Int(phase / (2 * .pi) * 64) % 64
    }
    private var session: UUID?
    private var cursor: UInt64 = 0
    private var sinceBeat = 100.0, period = 0.5, desiredPeriod = 0.5, strength = 0.0
    private var sampleRate: Double?, channels: Int?, audioTime: Double?

    mutating func reset() { self = PixelTailScene() }
    @discardableResult
    mutating func advance(_ input: FeatureInput, seconds: Double) -> Bool {
        let previous = spriteIndex
        let dt = seconds.isFinite ? max(0, seconds) : 0
        if session != input.sessionID { reset(); session = input.sessionID }
        sinceBeat += dt
        var latest: AudioBeatEvent?
        var running = false
        if input.state == .running, let frame = input.frame, frame.sessionID == input.sessionID,
           let age = input.frameAge, age.isFinite, age >= 0, age < 0.4, !frame.audio.isSilent {
            running = true
            let changed = sampleRate != nil && (sampleRate != frame.audio.sampleRate || channels != frame.audio.channelCount ||
                audioTime.map { frame.audio.time < $0 } == true)
            if changed { cursor = frame.sequence; sinceBeat = 100 }
            sampleRate = frame.audio.sampleRate; channels = frame.audio.channelCount; audioTime = frame.audio.time
            let now = frame.receivedAt + age
            for beat in input.beats ?? [] where beat.sequence > cursor && beat.sequence <= frame.sequence {
                let lag = now - beat.receivedAt
                guard lag.isFinite, lag >= 0, lag <= 0.15,
                      beat.bpm.isFinite, (50...200).contains(beat.bpm),
                      beat.confidence.isFinite, (0.45...1).contains(beat.confidence),
                      beat.strength.isFinite, (0...1).contains(beat.strength) else { continue }
                if latest == nil || beat.sequence > latest!.sequence { latest = beat }
            }
            cursor = max(cursor, frame.sequence)
            if let beat = latest {
                desiredPeriod = 60 / beat.bpm
                if beatCount == 0 { period = desiredPeriod }
                beatCount += 1; sinceBeat = now - beat.receivedAt
                strength = 0.88 + 0.12 * beat.strength
            }
        } else { cursor = max(cursor, input.frame?.sequence ?? 0) }
        let engaged = running && sinceBeat <= max(0.9, desiredPeriod * 1.5)
        // A newly arrived beat after a long stall starts now, never catches up old motion.
        let step = latest == nil ? dt : min(dt, 0.05)
        period += (desiredPeriod - period) * (1 - exp(-step / 0.14))
        let target = engaged ? strength : 0
        amplitude += (target - amplitude) * (1 - exp(-step / (engaged ? 0.055 : 0.08)))
        if !engaged && amplitude < 0.025 { amplitude = 0 }
        if amplitude > 0 {
            phase = (phase + Double.pi * step / period).truncatingRemainder(dividingBy: 2 * .pi)
        }
        return previous != spriteIndex
    }
}

/// The approved v2 concept, reconstructed at constant volume rather than playing
/// generated frames with changing lengths. Broad shaft, rounded tip and sparse fur.
/// One rest pose and four amplitudes × 64 continuous phases, cached by the renderer.
enum PixelTailSprite {
    static let width = 96, height = 88, frameCount = 257
    static func centerline(t: Double, phase: Double, amplitude: Double) -> (Double, Double) {
        let x = 12 + 66 * t
        let rest = 5 * sin(.pi * t) - 15 * pow(t, 3)
        let bend = max(0, (t - 0.12) / 0.88)
        let wave = amplitude * 13 * bend * bend * (3 - 2 * bend) * sin(phase - 2.4 * t)
        return (x, 48 + rest + wave)
    }
    static func pixels(index: Int) -> [(Int, Int)] {
        let amplitude = index == 0 ? 0 : Double((index - 1) / 64 + 1) / 4
        let phase = index == 0 ? 0 : Double((index - 1) % 64) * 2 * .pi / 64
        var samples = [(Double, Double, Double)]()
        for i in 0...100 {
            let t = Double(i) / 100
            let (x,y) = centerline(t: t, phase: phase, amplitude: amplitude)
            // Keep substantial thickness through the tip: never taper into a whip.
            let radius = 7.5 - 2.2 * t + 0.4 * sin(.pi * t)
            samples.append((x,y,radius))
            // Small tufts travel with the same material sections, avoiding flicker.
            if [22, 42, 64, 82].contains(i) {
                samples.append((x-1,y-radius+0.5,2))
            }
            if [32, 55, 74].contains(i) {
                samples.append((x-1,y+radius-0.5,2))
            }
        }
        // Rasterize only cells near the curve rather than testing every canvas cell
        // against every sample. This keeps first activation inexpensive.
        var cells = Set<Int>()
        for (cx,cy,radius) in samples {
            let x0 = max(0, Int(floor((cx-radius-1)/2))*2), x1 = min(width-2, Int(ceil((cx+radius-1)/2))*2)
            let y0 = max(0, Int(floor((cy-radius-1)/2))*2), y1 = min(height-2, Int(ceil((cy+radius-1)/2))*2)
            for y in stride(from: y0, through: y1, by: 2) {
                for x in stride(from: x0, through: x1, by: 2) {
                    let dx = Double(x+1)-cx, dy = Double(y+1)-cy
                    if dx*dx+dy*dy <= radius*radius { cells.insert(y*width+x) }
                }
            }
        }
        return cells.sorted().map { ($0 % width, $0 / width) }
    }
}
