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

    private lazy var app: (any MusicApplication)? = {
        SBApplication(bundleIdentifier: Self.bundleID)
    }()

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    /// Whether Automation permission is currently granted for Apple Music.
    var hasAutomationPermission: Bool {
        canAutomateApp(bundleID: Self.bundleID)
    }

    func playPause() {
        if hasAutomationPermission {
            Self.log.notice("playPause via ScriptingBridge")
            app?.playpause?()
        } else {
            Self.log.notice("playPause via CGEvent fallback (no Automation permission)")
            sendKey(code: 49) // Space
        }
    }

    func nextTrack() {
        if hasAutomationPermission {
            Self.log.notice("nextTrack via ScriptingBridge")
            app?.nextTrack?()
        } else {
            Self.log.notice("nextTrack via CGEvent fallback")
            sendKey(code: 124, flags: .maskCommand) // Cmd+Right
        }
    }

    func backTrack() {
        if hasAutomationPermission {
            Self.log.notice("backTrack via ScriptingBridge")
            app?.backTrack?()
        } else {
            Self.log.notice("backTrack via CGEvent fallback")
            sendKey(code: 123, flags: .maskCommand) // Cmd+Left
        }
    }

    // fastForward, rewind, resume have no keyboard equivalents —
    // keep ScriptingBridge only (used in iTunes-priority long-press).
    func fastForward() {
        Self.log.notice("fastForward via ScriptingBridge")
        app?.fastForward?()
    }

    func rewind() {
        Self.log.notice("rewind via ScriptingBridge")
        app?.rewind?()
    }

    func resume() {
        Self.log.notice("resume via ScriptingBridge")
        app?.resume?()
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
