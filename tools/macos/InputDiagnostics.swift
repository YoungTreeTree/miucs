import AppKit

/// Explicit, aggregate-only diagnostics: never exports key codes, held keys or individual timestamps.
@MainActor
enum InputDiagnostics {
    static func run(audio: AudioEngine, keyboard: KeyboardEngine, arguments: [String]) async {
        defer { keyboard.stop(); audio.stop(); NSApp.terminate(nil) }
        func argument(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let output = argument("--output") else {
            fputs("--diagnose-inputs requires --output\n", stderr); return
        }
        let requested = Double(argument("--duration") ?? "8") ?? 8
        let duration = requested.isFinite ? min(60, max(1, requested)) : 8
        await keyboard.start(requestAccess: arguments.contains("--request-keyboard-access"))
        await audio.start()
        let keys = keyboard.channel.subscribe(), sound = audio.channel.subscribe()
        let started = ProcessInfo.processInfo.systemUptime
        var keyStates = Set<String>(), audioStates = Set<String>()
        var counts = [String: Int](), audioFrames = 0, onsets = 0, simultaneousSamples = 0
        var audioSequence: UInt64 = 0, audioSession: UUID?
        var dropped: UInt64 = 0, maximumDeliveryAge = 0.0, maximumRate = 0.0
        while ProcessInfo.processInfo.systemUptime - started < duration {
            let input = keys.read(), frame = sound.read()
            keyStates.insert(input.state.rawValue); audioStates.insert(frame.state.rawValue)
            for event in input.events {
                counts[event.kind.rawValue, default: 0] += 1
                maximumDeliveryAge = max(maximumDeliveryAge, input.sampledAt - event.receivedAt)
            }
            dropped += input.droppedEventCount; maximumRate = max(maximumRate, input.pressesPerSecond)
            if let latest = frame.frame {
                if audioSession != latest.sessionID { audioSession = latest.sessionID; audioSequence = 0 }
                audioFrames += Int(latest.sequence - audioSequence); audioSequence = latest.sequence
            }
            onsets += frame.onsets.count
            if input.state == .running && frame.state == .running { simultaneousSamples += 1 }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        let report: [String: Any] = ["duration": ProcessInfo.processInfo.systemUptime - started,
            "keyboardStates": keyStates.sorted(), "audioStates": audioStates.sorted(),
            "keyboardEventsByKind": counts, "keyboardDroppedEvents": dropped,
            "maximumKeyboardDeliveryAgeMs": maximumDeliveryAge * 1000, "maximumPressesPerSecond": maximumRate,
            "audioFeatureFrames": audioFrames, "audioOnsets": onsets, "simultaneousRunningSamples": simultaneousSamples,
            "containsKeyCodesOrText": false]
        do {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            print("Input diagnostics saved to \(output)")
        } catch { fputs("Input diagnostics failed: \(error)\n", stderr) }
    }
}
