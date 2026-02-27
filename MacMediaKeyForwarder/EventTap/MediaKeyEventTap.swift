import Cocoa
import CoreGraphics

/// Intercepts system media key events via a `CGEventTap` and forwards parsed
/// `MediaKeyEvent` values through the `onMediaKeyEvent` closure.
final class MediaKeyEventTap {

    /// Called on the main thread when a media key event is detected.
    var onMediaKeyEvent: ((MediaKeyEvent) -> Void)?

    private var eventPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isListening = false

    deinit {
        stopListening()
        // CFMachPort and CFRunLoopSource are automatically managed in Swift via ARC.
        // Setting to nil is sufficient for cleanup.
        runLoopSource = nil
        eventPort = nil
    }

    // MARK: - Setup

    /// Creates the event tap. Returns `false` if accessibility permission is missing.
    @discardableResult
    func createTap() -> Bool {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // Try CGEventMaskBit first for better compatibility
        eventPort = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED),
            callback: mediaKeyTapCallback,
            userInfo: userInfo
        )

        // Fallback to NX_SYSDEFINEDMASK (same value, different spelling)
        if eventPort == nil {
            eventPort = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(NX_SYSDEFINEDMASK),
                callback: mediaKeyTapCallback,
                userInfo: userInfo
            )
        }

        guard let port = eventPort else { return false }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        return true
    }

    // MARK: - Listening Control

    func startListening() {
        guard let source = runLoopSource, !isListening else { return }
        let runLoop = CFRunLoopGetCurrent()
        if !CFRunLoopContainsSource(runLoop, source, .commonModes) {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        isListening = true
    }

    func stopListening() {
        guard let source = runLoopSource, isListening else { return }
        let runLoop = CFRunLoopGetCurrent()
        if CFRunLoopContainsSource(runLoop, source, .commonModes) {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        isListening = false
    }

    // MARK: - Callback Handling

    /// Called from the C callback; parses the event and invokes the handler.
    fileprivate func handleRawEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it due to timeout
        if type == .tapDisabledByTimeout {
            if let port = eventPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByUserInput {
            return Unmanaged.passUnretained(event)
        }

        // Only handle NX_SYSDEFINED events
        guard type.rawValue == UInt32(NX_SYSDEFINED) else {
            return Unmanaged.passUnretained(event)
        }

        // Convert to NSEvent for easier field access
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        // Media key events have subtype 8
        guard nsEvent.subtype.rawValue == kMediaKeyEventSubtype else {
            return Unmanaged.passUnretained(event)
        }

        // Extract key code from data1: bits 16-31
        let data1 = nsEvent.data1
        let keyCodeRaw = Int32((data1 & 0xFFFF_0000) >> 16)

        guard let keyCode = MediaKeyCode(rawValue: keyCodeRaw),
              keyCode == .play || keyCode == .fast || keyCode == .rewind ||
              keyCode == .next || keyCode == .previous else {
            return Unmanaged.passUnretained(event)
        }

        // Extract press state from data1: bits 8-15 (0xA = pressed)
        let keyFlags = data1 & 0x0000_FFFF
        let isPressed = ((keyFlags & 0xFF00) >> 8) == 0xA

        let mediaEvent = MediaKeyEvent(keyCode: keyCode, isPressed: isPressed)
        onMediaKeyEvent?(mediaEvent)

        // Consume the event (don't pass to other apps)
        return nil
    }
}

// MARK: - C Callback

/// Top-level function satisfying the `@convention(c)` requirement for `CGEvent.tapCreate`.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handleRawEvent(proxy: proxy, type: type, event: event)
}

// MARK: - IOKit Constants

/// NX_SYSDEFINEDMASK: bitmask for NX_SYSDEFINED event type.
/// Defined here in case IOKit headers don't export it to Swift.
private let NX_SYSDEFINEDMASK: Int64 = 1 << NX_SYSDEFINED
