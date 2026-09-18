import Cocoa
import CoreGraphics
import os.log

/// Intercepts system media key events via a `CGEventTap` and forwards parsed
/// `MediaKeyEvent` values through the `onMediaKeyEvent` closure.
///
/// The tap runs on its own thread and run loop, never the main one. A
/// `CGEventTap` callback that does not return promptly makes macOS disable the
/// tap, after which every media key falls through to the frontmost app. Keeping
/// the tap on a dedicated thread means that whatever the main thread is doing —
/// including blocking on IPC to a music player that stopped answering — the
/// keys are still captured, still consumed, and the tap is still re-armed.
final class MediaKeyEventTap {

    private static let log = Logger(
        subsystem: "eu.meyer.mmkf", category: "MediaKeyEventTap"
    )

    /// Called on the tap's own thread when a media key event is detected.
    /// Handlers must hop to whatever queue they need and must not block.
    var onMediaKeyEvent: ((MediaKeyEvent) -> Void)?

    /// Set once in `createTap()`, before the tap thread starts, and read from
    /// the tap thread afterwards.
    private var eventPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let lock = NSLock()
    private var isListening = false
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    /// Signalled once the tap thread's run loop is ready to take work.
    private let runLoopReady = DispatchSemaphore(value: 0)

    deinit {
        if let port = eventPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
        }
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

        guard let port = eventPort else {
            Self.log.error("Failed to create event tap — accessibility permission missing?")
            return false
        }

        Self.log.notice("Event tap created successfully")
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        return true
    }

    // MARK: - Listening Control

    func startListening() {
        lock.lock()
        guard runLoopSource != nil, !isListening else {
            lock.unlock()
            return
        }
        isListening = true
        let threadExists = tapThread != nil
        lock.unlock()

        if threadExists {
            performOnTapRunLoop { [weak self] in self?.attachSource() }
        } else {
            startTapThread() // attaches the source as soon as its run loop is up
        }
        Self.log.notice("Event tap listening started")
    }

    func stopListening() {
        lock.lock()
        guard isListening else {
            lock.unlock()
            return
        }
        isListening = false
        lock.unlock()

        performOnTapRunLoop { [weak self] in self?.detachSource() }
        Self.log.notice("Event tap listening stopped")
    }

    // MARK: - Tap Thread

    private func startTapThread() {
        let thread = Thread { [weak self] in self?.runTapThread() }
        thread.name = "eu.meyer.mmkf.MediaKeyEventTap"
        thread.qualityOfService = .userInteractive

        lock.lock()
        tapThread = thread
        lock.unlock()

        thread.start()
        // Bounded, so a thread that fails to start can never hang the caller.
        _ = runLoopReady.wait(timeout: .now() + 2.0)
    }

    private func runTapThread() {
        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        tapRunLoop = runLoop
        lock.unlock()

        attachSource()

        // Re-arms the tap if the system disabled it, and keeps the run loop
        // alive while the source is detached.
        let healthTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.reEnableTapIfNeeded()
        }
        RunLoop.current.add(healthTimer, forMode: .common)

        runLoopReady.signal()
        CFRunLoopRun()
    }

    /// Runs `block` on the tap thread's run loop. No-op until it is up.
    private func performOnTapRunLoop(_ block: @escaping () -> Void) {
        lock.lock()
        let runLoop = tapRunLoop
        lock.unlock()

        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Tap thread only.
    private func attachSource() {
        guard let source = runLoopSource else { return }
        let runLoop = CFRunLoopGetCurrent()
        if !CFRunLoopContainsSource(runLoop, source, .commonModes) {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        if let port = eventPort {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    /// Tap thread only.
    private func detachSource() {
        if let port = eventPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        guard let source = runLoopSource else { return }
        let runLoop = CFRunLoopGetCurrent()
        if CFRunLoopContainsSource(runLoop, source, .commonModes) {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
    }

    /// Periodically checks if the event tap is still enabled and re-enables it
    /// if the system disabled it (e.g., due to timeout or permission changes).
    private func reEnableTapIfNeeded() {
        lock.lock()
        let listening = isListening
        lock.unlock()

        guard listening, let port = eventPort else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            Self.log.warning("Event tap was disabled by system — re-enabling")
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    // MARK: - Callback Handling

    /// Called from the C callback on the tap thread; parses the event and
    /// invokes the handler.
    fileprivate func handleRawEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it due to timeout
        if type == .tapDisabledByTimeout {
            Self.log.warning("Event tap disabled by timeout — re-enabling")
            if let port = eventPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByUserInput {
            Self.log.warning("Event tap disabled by user input — re-enabling")
            if let port = eventPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
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
