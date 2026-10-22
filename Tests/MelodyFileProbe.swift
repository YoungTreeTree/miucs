import AVFoundation
import Foundation

@main
struct MelodyFileProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw AudioAnalysisError.invalidInput("melody-file-probe input-audio output.json") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        let analyzer = try MelodyAnalyzer()
        var frames = [MelodyFrame]()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = (0..<Int(buffer.format.channelCount)).map {
                Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
            }
            frames += try analyzer.process(channels: channels, sampleRate: file.processingFormat.sampleRate)
        }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(frames).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
