import Foundation
#if canImport(RapidlyEngineC)
import RapidlyEngineC
#endif

enum RapidlyFailure: Error, CustomStringConvertible {
    case unavailable, missingModel, invalidLicense, unsupportedLicense, model, bus, output

    var description: String {
        switch self {
        case .unavailable: return "此构建未包含 Rapidly"
        case .missingModel: return "缺少 Rapidly 音乐模型"
        case .invalidLicense: return "Rapidly 离线授权文件无效或无法读取"
        case .unsupportedLicense: return "此接入支持 lk_ 离线授权；在线授权尚未配置"
        case .model: return "Rapidly 音乐模型加载失败"
        case .bus: return "Rapidly 模型没有 vocals 输出"
        case .output: return "Rapidly 返回无效音频"
        }
    }
}

struct RapidlyConfiguration {
    static let modelName = "music-stem-separation-96ms.v1.1.rapidly"
    let modelURL: URL
    let licenseFile: URL?

    static func bundled() throws -> Self {
        guard let resources = Bundle.main.resourceURL else { throw RapidlyFailure.missingModel }
        let directory = resources.appendingPathComponent("Rapidly", isDirectory: true)
        let explicit = ProcessInfo.processInfo.environment["MIUCS_RAPIDLY_LICENSE_FILE"]
        let standard = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Miucs/rapidly-license.txt")
        let key = explicit.map { URL(fileURLWithPath: $0) }
            ?? (FileManager.default.fileExists(atPath: standard.path) ? standard : nil)
        return Self(modelURL: directory.appendingPathComponent(modelName), licenseFile: key)
    }
}

/// One capture owns one processor, exclusively on its serial audio queue.
/// The SDK exposes a mix of output busses: explicitly retain only `vocals`.
/// Demo watermarking is left intact. No playback or licensing network is used.
final class RapidlyVocalProcessor: VocalPCMProcessor {
    static var isAvailable: Bool {
        #if canImport(RapidlyEngineC)
        true
        #else
        false
        #endif
    }
    private let configuration: RapidlyConfiguration
    let hasAcceptedOfflineKey: Bool
    var statusDescription: String {
        hasAcceptedOfflineKey ? "Rapidly · 已载入离线授权" : "Rapidly 试用 · 含水印"
    }
    private(set) var maximumLatencySeconds = 0.0
    private(set) var busNames = [String]()
    private var sampleRate = 0.0
    private var channelCount = 0
    private var input = [Float]()
    private var output = [Float]()
    #if canImport(RapidlyEngineC)
    private var handle: RapidlyProcessorHandle?
    #endif

    init(configuration: RapidlyConfiguration) throws {
        self.configuration = configuration
        #if canImport(RapidlyEngineC)
        guard FileManager.default.isReadableFile(atPath: configuration.modelURL.path) else {
            throw RapidlyFailure.missingModel
        }
        if let file = configuration.licenseFile {
            guard let data = try? Data(contentsOf: file), data.count <= 65_536,
                  let text = String(data: data, encoding: .utf8) else { throw RapidlyFailure.invalidLicense }
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("lk_") else { throw RapidlyFailure.unsupportedLicense }
            guard rapidlyAddLicense(key) else { throw RapidlyFailure.invalidLicense }
            hasAcceptedOfflineKey = true
        } else { hasAcceptedOfflineKey = false }
        try configure(rate: 48_000, channels: 2)
        #else
        hasAcceptedOfflineKey = false
        throw RapidlyFailure.unavailable
        #endif
    }

    deinit {
        #if canImport(RapidlyEngineC)
        if let handle { rapidlyDeleteProcessor(handle) }
        #endif
    }

    func reset() {
        #if canImport(RapidlyEngineC)
        if let handle { rapidlyResetProcessorState(handle) }
        #endif
    }

    func process(_ block: AudioPCMBlock) throws -> AudioPCMBlock? {
        guard block.sampleRate.isFinite, (8_000...192_000).contains(block.sampleRate),
              (1...2).contains(block.channels.count), let count = block.channels.first?.count,
              block.channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw AudioAnalysisError.invalidInput("Invalid vocal separation PCM")
        }
        guard count > 0 else { return nil }
        #if canImport(RapidlyEngineC)
        if sampleRate != block.sampleRate || channelCount != block.channels.count {
            try configure(rate: block.sampleRate, channels: block.channels.count)
        }
        guard let handle else { throw RapidlyFailure.model }
        var separated = [[Float]](repeating: [], count: channelCount)
        for c in separated.indices { separated[c].reserveCapacity(count + 4096) }
        // Keep each SDK submission bounded even when capture delivers a large batch.
        for offset in stride(from: 0, to: count, by: 512) {
            let frames = min(512, count - offset)
            for i in 0..<frames {
                for c in 0..<channelCount { input[i * channelCount + c] = block.channels[c][offset + i] }
            }
            rapidlyAddAudioInterleaved(handle, input, Int32(frames))
            let pending = Int(rapidlyGetNumOfPendingSamples(handle))
            guard (0...16_384).contains(pending) else { throw RapidlyFailure.output }
            if pending > 0 {
                if output.count < pending * channelCount { output = .init(repeating: 0, count: pending * channelCount) }
                guard rapidlyGetAudioInterleaved(handle, &output, Int32(pending)) else { throw RapidlyFailure.output }
                for i in 0..<pending {
                    for c in 0..<channelCount {
                        let value = output[i * channelCount + c]
                        guard value.isFinite else { throw RapidlyFailure.output }
                        separated[c].append(value)
                    }
                }
            }
        }
        guard !separated[0].isEmpty else { return nil }
        return AudioPCMBlock(channels: separated, sampleRate: sampleRate, isInterleaved: false)
        #else
        throw RapidlyFailure.unavailable
        #endif
    }

    #if canImport(RapidlyEngineC)
    private func configure(rate: Double, channels: Int) throws {
        if let handle { rapidlyDeleteProcessor(handle); self.handle = nil }
        guard let fresh = rapidlyCreateProcessor(configuration.modelURL.path, Int32(channels), rate) else {
            throw RapidlyFailure.model
        }
        var configured = false
        defer { if !configured { rapidlyDeleteProcessor(fresh); handle = nil } }
        handle = fresh
        var names = [String]()
        let busCount = rapidlyGetNumOfOutputBusses(fresh)
        guard (1...32).contains(busCount) else { throw RapidlyFailure.bus }
        for bus in 0..<busCount {
            var buffer = [CChar](repeating: 0, count: 256)
            rapidlyGetOutputBusName(fresh, bus, &buffer, Int32(buffer.count))
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            names.append(name)
            rapidlySetParameterValue(fresh, Int32(RAPIDLY_PARAM_BUS_GAINS) + bus,
                                     name.lowercased() == "vocals" ? 1 : 0)
        }
        guard names.contains(where: { $0.lowercased() == "vocals" }) else { throw RapidlyFailure.bus }
        busNames = names
        var info = RapidlyProcessorInfo()
        rapidlyGetProcessorInfo(fresh, &info)
        guard info.sampleRate > 0, info.latencyInSamples >= 0 else { throw RapidlyFailure.model }
        maximumLatencySeconds = Double(info.latencyInSamples) / info.sampleRate
        sampleRate = rate; channelCount = channels
        input = .init(repeating: 0, count: 512 * channels)
        output = .init(repeating: 0, count: 16_384 * channels)
        configured = true
    }
    #endif
}
