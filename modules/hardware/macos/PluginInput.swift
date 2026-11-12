import Foundation

public enum PluginInput {
    public static func audio(_ input: FeatureInput) -> [String: Any] {
        var result: [String: Any] = ["version": 1, "sessionID": input.sessionID.uuidString, "state": input.state.rawValue,
            "frameAge": input.frameAge as Any? ?? NSNull(), "spectralFluxPeak": input.spectralFluxPeak,
            "onsets": input.onsets.map { ["sequence": $0.sequence, "time": $0.time, "receivedAt": $0.receivedAt, "strength": $0.strength] as [String: Any] },
            "beats": (input.beats ?? []).map { ["sequence": $0.sequence, "time": $0.time, "receivedAt": $0.receivedAt, "strength": $0.strength, "bpm": $0.bpm, "confidence": $0.confidence] as [String: Any] }]
        if let frame = input.frame {
            let a = frame.audio
            var values: [String: Any] = [
                "time": a.time,
                "sampleRate": a.sampleRate,
                "channelCount": a.channelCount,
                "rms": a.rms,
                "rmsDBFS": a.rmsDBFS,
                "peak": a.peak,
                "crestDB": a.crestDB as Any? ?? NSNull(),
                "envelope": a.envelope,
                "isSilent": a.isSilent,
                "silenceDuration": a.silenceDuration,
                "lowEnergy": a.lowEnergy,
                "midEnergy": a.midEnergy,
                "highEnergy": a.highEnergy,
                "lowShare": a.lowShare as Any? ?? NSNull(),
                "midShare": a.midShare as Any? ?? NSNull(),
                "highShare": a.highShare as Any? ?? NSNull(),
                "centroidHz": a.centroidHz as Any? ?? NSNull(),
                "bandwidthHz": a.bandwidthHz as Any? ?? NSNull(),
                "flatness": a.flatness as Any? ?? NSNull(),
                "spectralFlux": a.spectralFlux,
                "onsetThreshold": a.onsetThreshold,
                "isOnset": a.isOnset,
                "balance": a.balance as Any? ?? NSNull(),
                "sideEnergyRatio": a.sideEnergyRatio as Any? ?? NSNull(),
                "correlation": a.correlation as Any? ?? NSNull(),
                "displayBands": a.displayBands
            ]
            if let b = a.beat { values["beat"] = ["time": b.time, "bpm": b.bpm as Any? ?? NSNull(), "phase": b.phase as Any? ?? NSNull(), "confidence": b.confidence, "strength": b.strength, "beatTime": b.beatTime as Any? ?? NSNull()] }
            var f: [String: Any] = ["version": 1, "sessionID": frame.sessionID.uuidString, "sequence": frame.sequence, "receivedAt": frame.receivedAt, "audio": values]
            if let m = frame.melody { f["melody"] = ["time": m.time, "pitchHz": m.pitchHz as Any? ?? NSNull(), "confidence": m.confidence, "isMelodic": m.isMelodic] }
            result["frame"] = f
        }
        return result
    }
    public static func keyboard(_ input: KeyboardInput) -> [String: Any] {
        ["version": 1, "sessionID": input.sessionID.uuidString, "sequence": input.sequence,
         "state": input.state.rawValue, "sampledAt": input.sampledAt, "modifiers": input.modifiers.rawValue,
         "pressesPerSecond": input.pressesPerSecond, "idleDuration": input.idleDuration as Any? ?? NSNull(),
         "droppedEventCount": input.droppedEventCount,
         "heldKeys": input.heldKeys.map { ["key": MacPhysicalKeys.names[$0.keyCode] as Any? ?? NSNull(), "duration": $0.duration] as [String: Any] },
         "events": input.events.map { e -> [String: Any] in
             ["sequence": e.sequence, "receivedAt": e.receivedAt, "kind": e.kind.rawValue,
              "key": MacPhysicalKeys.names[e.keyCode] as Any? ?? NSNull(), "modifiers": e.modifiers.rawValue,
              "heldDuration": e.heldDuration as Any? ?? NSNull(), "modifierIsPressed": e.modifierIsPressed as Any? ?? NSNull()]
         }]
    }
}
