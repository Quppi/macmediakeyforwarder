import Cocoa
import ScriptingBridge
import os.log

// MARK: - ScriptingBridge Protocol

@objc private protocol MusicApplication {
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func backTrack()
    @objc optional func fastForward()
    @objc optional func rewind()
    @objc optional func resume()
}

extension SBApplication: MusicApplication {}

// MARK: - Apple Music Bridge

/// Controls Apple Music via ScriptingBridge when Automation permission is
/// granted, falling back to CGEvent keyboard simulation for basic controls.
final class AppleMusicBridge {

    static let bundleID = "com.apple.Music"

    private static let log = Logger(
        subsystem: "eu.meyer.mmkf", category: "AppleMusicBridge"
    )

    /// Serial queue for every Apple Event sent to Apple Music.
    /// See `SpotifyBridge.commandQueue` for why these must not run on the
    /// main thread.
    private let commandQueue = DispatchQueue(
        label: "eu.meyer.mmkf.applemusic-commands", qos: .userInitiated
    )

    /// Built eagerly so the command queue never races on lazy initialization.
    private let app: (any MusicApplication)?

    init() {
        let app = SBApplication(bundleIdentifier: Self.bundleID)
        // Fire and forget: media transport commands have no useful reply, and
        // never let Apple Music put up UI that we would then be waiting on.
        app?.sendMode = AESendMode(kAENoReply | kAENeverInteract)
        // Bounds the connect handshake, in ticks (1/60 s).
        app?.timeout = 120
        self.app = app

        AutomationPermissionMonitor.shared.refresh(bundleID: Self.bundleID)
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    /// Whether Automation permission is currently granted for Apple Music.
    /// Reads the cached status — never blocks (the live check can hang).
    var hasAutomationPermission: Bool {
        AutomationPermissionMonitor.shared.canAutomate(bundleID: Self.bundleID)
    }

    func playPause() {
        if hasAutomationPermission {
            Self.log.notice("playPause via ScriptingBridge")
            perform { $0.playpause?() }
        } else {
            Self.log.notice("playPause via CGEvent fallback (no Automation permission)")
            sendKey(code: 49) // Space
        }
    }

    func nextTrack() {
        if hasAutomationPermission {
            Self.log.notice("nextTrack via ScriptingBridge")
            perform { $0.nextTrack?() }
        } else {
            Self.log.notice("nextTrack via CGEvent fallback")
            sendKey(code: 124, flags: .maskCommand) // Cmd+Right
        }
    }

    func backTrack() {
        if hasAutomationPermission {
            Self.log.notice("backTrack via ScriptingBridge")
            perform { $0.backTrack?() }
        } else {
            Self.log.notice("backTrack via CGEvent fallback")
            sendKey(code: 123, flags: .maskCommand) // Cmd+Left
        }
    }

    // fastForward, rewind, resume have no keyboard equivalents —
    // keep ScriptingBridge only (used in iTunes-priority long-press).
    func fastForward() {
        Self.log.notice("fastForward via ScriptingBridge")
        perform { $0.fastForward?() }
    }

    func rewind() {
        Self.log.notice("rewind via ScriptingBridge")
        perform { $0.rewind?() }
    }

    func resume() {
        Self.log.notice("resume via ScriptingBridge")
        perform { $0.resume?() }
    }

    /// Sends an Apple Event off the main thread — see `commandQueue`.
    private func perform(_ command: @escaping (any MusicApplication) -> Void) {
        guard let app else { return }
        commandQueue.async { command(app) }
    }

    // MARK: - CGEvent Fallback

    private var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    private func sendKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let pid = runningApp?.processIdentifier else { return }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up   = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        if !flags.isEmpty {
            down?.flags = flags
            up?.flags = flags
        }
        down?.postToPid(pid)
        up?.postToPid(pid)
    }
}
