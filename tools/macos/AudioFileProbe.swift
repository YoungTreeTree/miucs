import AVFoundation
import Foundation

/// Offline entry point for reproducing measurements against an independent reference.
@main
private struct AudioFileProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw AudioAnalysisError.invalidInput("Usage: audio-file-probe <input-audio> <output.json>")
        }
        let file = try AVAudioFile(
            forReading: URL(fileURLWithPath: CommandLine.arguments[1]),
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        let analyzer = try AudioFeatureAnalyzer()
        var frames = [AudioFeatures]()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let channels = (0..<Int(buffer.format.channelCount)).map { channel in
                Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
            frames += try analyzer.process(channels: channels, sampleRate: file.processingFormat.sampleRate)
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(frames).write(to: destination, options: .atomic)
        print("Analyzed \(frames.count) frames → \(destination.path)")
    }
}
