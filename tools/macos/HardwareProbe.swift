#if canImport(MiucsCore)
import MiucsCore
#endif
import Foundation

/// Explicit, bounded hardware test. Uses the production USB discovery and transport.
@main
enum HardwareProbe {
    static func main() async {
        let args = CommandLine.arguments
        func argument(_ flag: String, _ fallback: String) -> String {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return fallback }
            return args[index + 1]
        }
        let ports = HardwarePort.connected().filter { $0.name == "Miucs P4 Display" }
        if args.contains("--list") {
            for port in ports { print("\(port.path)\t\(port.name)") }
            return
        }
        let output = argument("--output", "build/hardware-live-probe.json")
        let seconds = min(60, max(1, Double(argument("--seconds", "15")) ?? 15))
        let path = argument("--port", ports.first?.path ?? "")
        let folder = URL(fileURLWithPath: argument("--frames", "build/hardware-previews"))
        let serial = HardwareSerial()
        var report: [String: Any] = ["port": path, "passed": false, "secondsRequested": seconds]
        do {
            guard !path.isEmpty else { throw HardwareSerialError.message("没有检测到 Miucs P4 Display USB 设备") }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
            guard !files.isEmpty else { throw HardwareSerialError.message("没有测试 JPEG") }
            let frames = try files.map { try Data(contentsOf: $0) }
            guard try await serial.connect(path: path) == .miucs else {
                throw HardwareSerialError.message("此探测程序需要 Miucs 整屏固件")
            }
            let start = ProcessInfo.processInfo.systemUptime
            var sequence: UInt32 = 0
            var bytes = 0, decodeMS = [Int](), roundTripMS = [Double]()
            while ProcessInfo.processInfo.systemUptime - start < seconds {
                let index = Int(sequence) % frames.count
                sequence += 1
                guard let packet = HardwareFrame.packet(jpeg: frames[index], sequence: sequence) else {
                    throw HardwareSerialError.message("测试图片超过帧大小限制")
                }
                let sent = ProcessInfo.processInfo.systemUptime
                decodeMS.append(try await serial.send(packet, sequence: sequence))
                roundTripMS.append((ProcessInfo.processInfo.systemUptime - sent) * 1000)
                bytes += packet.count
                if sequence <= frames.count { print("FRAME_OK \(files[index].lastPathComponent) \(decodeMS.last!) ms") }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            report["frames"] = sequence
            report["elapsedSeconds"] = elapsed
            report["framesPerSecond"] = Double(sequence) / elapsed
            report["bytesPerSecond"] = Double(bytes) / elapsed
            report["averageDisplayMS"] = Double(decodeMS.reduce(0, +)) / Double(decodeMS.count)
            report["averageRoundTripMS"] = roundTripMS.reduce(0, +) / Double(roundTripMS.count)
            report["maxRoundTripMS"] = roundTripMS.max()
            report["skins"] = files.map { $0.deletingPathExtension().lastPathComponent }
            // Verify a corrupted payload is rejected, then reconnect using the normal handshake.
            var corrupted = HardwareFrame.packet(jpeg: frames[0], sequence: sequence + 1)!
            corrupted[corrupted.count - 1] ^= 1
            do {
                _ = try await serial.send(corrupted, sequence: sequence + 1)
                throw HardwareSerialError.message("损坏帧未被拒绝")
            } catch {
                guard error.localizedDescription.contains("屏幕未能显示此帧") else { throw error }
                report["crcRejected"] = true
            }
            try await serial.connect(path: path)
            _ = try await serial.send(HardwareFrame.packet(jpeg: frames[0], sequence: sequence + 2)!, sequence: sequence + 2)
            report["reconnectPassed"] = true
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription }
        await serial.close()
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output))
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("Could not write hardware report: \(error)\n", stderr) }
        if report["passed"] as? Bool != true { exit(1) }
    }
}
