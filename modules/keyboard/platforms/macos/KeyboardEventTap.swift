import Foundation
import CoreGraphics
import Carbon

protocol KeyboardCaptureSession: AnyObject, Sendable {
    func start() async throws
    func stop()
}

enum KeyboardCaptureError: Error { case unavailable, stopped }

/// A dedicated run loop owns the passive tap. Its callback only decodes numeric fields.
final class KeyboardEventTap: KeyboardCaptureSession, @unchecked Sendable {
    static let eventMask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged]
        .reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
    private let onEvent: @Sendable (KeyboardRawEvent) -> Void
    private let onInterruption: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var runLoop: CFRunLoop?

    init(onEvent: @escaping @Sendable (KeyboardRawEvent) -> Void,
         onInterruption: @escaping @Sendable () -> Void) {
        self.onEvent = onEvent; self.onInterruption = onInterruption
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard !started, !stopped else {
                lock.unlock(); continuation.resume(throwing: KeyboardCaptureError.stopped); return
            }
            started = true; lock.unlock()
            let thread = Thread { [self] in run(continuation) }
            thread.name = "Miucs.KeyboardEvents"; thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    func stop() {
        lock.lock(); stopped = true; let loop = runLoop; lock.unlock()
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    private func run(_ continuation: CheckedContinuation<Void, Error>) {
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: Self.eventMask, callback: keyboardTapCallback, userInfo: info),
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            continuation.resume(throwing: KeyboardCaptureError.unavailable); return
        }
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .commonModes)
        lock.lock(); runLoop = loop; let shouldRun = !stopped; lock.unlock()
        continuation.resume()
        if shouldRun {
            // Bounded runs also close the stop-before-CFRunLoopRun race without blocking the main thread.
            while true {
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { break }
                let result = CFRunLoopRunInMode(.defaultMode, 0.25, false)
                if result == .finished || !CFMachPortIsValid(tap) {
                    onInterruption(); break
                }
            }
        }
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        lock.lock(); runLoop = nil; lock.unlock()
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onInterruption()
        } else if let input = Self.decode(type: type, event: event) {
            onEvent(input)
        }
    }

    static func decode(type: CGEventType, event: CGEvent) -> KeyboardRawEvent? {
        let kind: KeyboardEventKind
        switch type {
        case .keyDown: kind = event.getIntegerValueField(.keyboardEventAutorepeat) == 0 ? .pressed : .repeated
        case .keyUp: kind = .released
        case .flagsChanged: kind = .modifiersChanged
        default: return nil
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let keyCode = UInt16(exactly: code) else { return nil }
        var modifiers: KeyboardModifiers = []
        for (native, portable) in [(CGEventFlags.maskShift, KeyboardModifiers.shift),
            (.maskControl, .control), (.maskAlternate, .option), (.maskCommand, .command),
            (.maskAlphaShift, .capsLock), (.maskSecondaryFn, .function)] {
            if event.flags.contains(native) { modifiers.insert(portable) }
        }
        return KeyboardRawEvent(kind: kind, keyCode: keyCode, modifiers: modifiers,
            modifierIsPressed: kind == .modifiersChanged ? modifierState(keyCode: keyCode, flags: event.flags) : nil)
    }

    private static func modifierState(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        // Device-dependent flags distinguish releasing one side while the other remains down.
        // These masks are declared by the SDK's IOKit/hidsystem/IOLLEvent.h.
        let sides: (Int32, Int32, CGEventFlags)
        switch Int(keyCode) {
        case kVK_Shift: sides = (NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK, .maskShift)
        case kVK_RightShift: sides = (NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK, .maskShift)
        case kVK_Control: sides = (NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK, .maskControl)
        case kVK_RightControl: sides = (NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK, .maskControl)
        case kVK_Option: sides = (NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK, .maskAlternate)
        case kVK_RightOption: sides = (NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK, .maskAlternate)
        case kVK_Command: sides = (NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK, .maskCommand)
        case kVK_RightCommand: sides = (NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK, .maskCommand)
        case kVK_Function: return flags.contains(.maskSecondaryFn)
        case kVK_CapsLock: return flags.contains(.maskAlphaShift)
        default: return nil
        }
        if flags.rawValue & UInt64(sides.0) != 0 { return true }
        if flags.rawValue & UInt64(sides.1) != 0 || !flags.contains(sides.2) { return false }
        // Aggregate-only synthetic events cannot identify which side changed.
        return nil
    }
}

private func keyboardTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                 _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let info { Unmanaged<KeyboardEventTap>.fromOpaque(info).takeUnretainedValue().receive(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
