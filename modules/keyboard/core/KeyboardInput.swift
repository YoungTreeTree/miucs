import Foundation

public enum KeyboardSourceState: String, Codable, Sendable {
    case stopped, connecting, running, permissionRequired, suspended, secureInput, recovering
}

/// Portable modifier bits; keyCode is the platform's physical key identifier (macOS virtual key code).
public struct KeyboardModifiers: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)
    public static let function = Self(rawValue: 1 << 5)
}

public enum KeyboardEventKind: String, Codable, Sendable {
    case pressed, released, repeated, modifiersChanged
}

/// No characters, text composition, application identity or clipboard content crosses this boundary.
public struct KeyboardRawEvent: Sendable {
    public let kind: KeyboardEventKind
    public let keyCode: UInt16
    public let modifiers: KeyboardModifiers
    /// Physical modifier transition when the platform can resolve its side; Caps Lock is its lock state.
    public var modifierIsPressed: Bool? = nil
}

public struct KeyboardInputEvent: Codable, Sendable {
    public let sequence: UInt64
    public let receivedAt: Double
    public let kind: KeyboardEventKind
    public let keyCode: UInt16
    public let modifiers: KeyboardModifiers
    /// Known only when this channel observed the corresponding press.
    public let heldDuration: Double?
    public var modifierIsPressed: Bool? = nil
}

public struct KeyboardHeldKey: Codable, Sendable {
    public let keyCode: UInt16
    public let duration: Double
}

public struct KeyboardInput: Codable, Sendable {
    public var version = 1
    public let sessionID: UUID
    public let sequence: UInt64
    public let state: KeyboardSourceState
    public let sampledAt: Double
    public let modifiers: KeyboardModifiers
    public let heldKeys: [KeyboardHeldKey]
    /// Non-repeat, non-modifier presses in the last second, capped at the channel's rate capacity.
    public let pressesPerSecond: Double
    public let idleDuration: Double?
    public let events: [KeyboardInputEvent]
    /// Number of unread events lost to age/capacity for this reader, never replayed later.
    public let droppedEventCount: UInt64
}

public protocol KeyboardFeatureSource: Sendable {
    func subscribe() -> KeyboardSubscription
}
