import Foundation

enum KeyboardSourceState: String, Codable, Sendable {
    case stopped, connecting, running, permissionRequired, suspended, secureInput, recovering
}

/// Portable modifier bits; keyCode is the platform's physical key identifier (macOS virtual key code).
struct KeyboardModifiers: OptionSet, Codable, Sendable, Equatable {
    let rawValue: UInt8
    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let capsLock = Self(rawValue: 1 << 4)
    static let function = Self(rawValue: 1 << 5)
}

enum KeyboardEventKind: String, Codable, Sendable {
    case pressed, released, repeated, modifiersChanged
}

/// No characters, text composition, application identity or clipboard content crosses this boundary.
struct KeyboardRawEvent: Sendable {
    let kind: KeyboardEventKind
    let keyCode: UInt16
    let modifiers: KeyboardModifiers
    /// Physical modifier transition when the platform can resolve its side; Caps Lock is its lock state.
    var modifierIsPressed: Bool? = nil
}

struct KeyboardInputEvent: Codable, Sendable {
    let sequence: UInt64
    let receivedAt: Double
    let kind: KeyboardEventKind
    let keyCode: UInt16
    let modifiers: KeyboardModifiers
    /// Known only when this channel observed the corresponding press.
    let heldDuration: Double?
    var modifierIsPressed: Bool? = nil
}

struct KeyboardHeldKey: Codable, Sendable {
    let keyCode: UInt16
    let duration: Double
}

struct KeyboardInput: Codable, Sendable {
    var version = 1
    let sessionID: UUID
    let sequence: UInt64
    let state: KeyboardSourceState
    let sampledAt: Double
    let modifiers: KeyboardModifiers
    let heldKeys: [KeyboardHeldKey]
    /// Non-repeat, non-modifier presses in the last second, capped at the channel's rate capacity.
    let pressesPerSecond: Double
    let idleDuration: Double?
    let events: [KeyboardInputEvent]
    /// Number of unread events lost to age/capacity for this reader, never replayed later.
    let droppedEventCount: UInt64
}

protocol KeyboardFeatureSource: Sendable {
    func subscribe() -> KeyboardSubscription
}
