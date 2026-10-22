import CoreAudio
import CoreMedia
import Foundation

struct AudioPCMBlock: Sendable {
    var channels: [[Float]]
    var sampleRate: Double
    var isInterleaved: Bool
}

/// Retains channel identity for both ScreenCaptureKit Float32 PCM layouts.
enum AudioPCMDecoder {
    static func decode(_ sampleBuffer: CMSampleBuffer) throws -> AudioPCMBlock {
        guard sampleBuffer.isValid,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (1...2).contains(Int(asbd.mChannelsPerFrame))
        else { throw AudioAnalysisError.invalidInput("Expected native Float32 mono/stereo PCM") }

        var needed = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard sizeStatus == noErr, needed > 0 else {
            throw AudioAnalysisError.invalidInput("Cannot read PCM buffer list: \(sizeStatus)")
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        var retainedBlock: CMBlockBuffer?
        let readStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: raw.bindMemory(to: AudioBufferList.self, capacity: 1),
            bufferListSize: needed, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock
        )
        guard readStatus == noErr else {
            throw AudioAnalysisError.invalidInput("Cannot retain PCM buffer list: \(readStatus)")
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        )
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let expectedStride = MemoryLayout<Float>.size * (interleaved ? channelCount : 1)
        guard Int(asbd.mBytesPerFrame) == expectedStride else {
            throw AudioAnalysisError.invalidInput("Padded Float32 PCM is not supported")
        }
        guard frames > 0 else { throw AudioAnalysisError.invalidInput("Empty PCM buffer") }
        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)

        if interleaved {
            guard buffers.count == 1, let buffer = buffers.first,
                  Int(buffer.mNumberChannels) == channelCount,
                  Int(buffer.mDataByteSize) >= frames * channelCount * MemoryLayout<Float>.size,
                  let data = buffer.mData
            else { throw AudioAnalysisError.invalidInput("Incomplete interleaved PCM buffer") }
            let samples = data.bindMemory(to: Float.self, capacity: frames * channelCount)
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    channels[channel][frame] = samples[frame * channelCount + channel]
                }
            }
        } else {
            guard buffers.count == channelCount else {
                throw AudioAnalysisError.invalidInput("Incomplete planar PCM channel list")
            }
            for channel in 0..<channelCount {
                let buffer = buffers[channel]
                guard buffer.mNumberChannels == 1,
                      Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size,
                      let data = buffer.mData
                else { throw AudioAnalysisError.invalidInput("Incomplete planar PCM buffer") }
                channels[channel] = Array(UnsafeBufferPointer(
                    start: data.bindMemory(to: Float.self, capacity: frames), count: frames
                ))
            }
        }
        return AudioPCMBlock(channels: channels, sampleRate: asbd.mSampleRate, isInterleaved: interleaved)
    }
}
